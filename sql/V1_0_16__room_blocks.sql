-- ----------------------------------------------------------------------
-- V1_0_16(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다): 연습실 시간 막기 (U46 — 사용자 요청 2026-11-23)
-- 배경: 관리자가 대시보드에서 연습실 시간을 직접 막는다(매주 반복 가능, 언제까지 막을지는 관리자가 정함, 삭제하면 즉시 풀림).
--       팀 예약이 막힌 시간과 겹치면 서버가 409 로 거부한다. 발생분은 행으로 펼치지 않고 규칙으로 계산한다(서버).
-- 범위:
--   ① room_blocks(신규) — 제목(30자) · 메모(선택) · 반복(NONE·WEEKLY) · 요일(ISO 1=월 … 7=일, WEEKLY 만) ·
--      시작·끝 분(0~1440, 30분 단위, 30분~하루 — 4시간 제한 없음) · 시작일·종료일(NONE 이면 같은 날) · 이 날만 해제(skip_dates).
--      시각은 TIME 대신 분(SMALLINT)으로 둔다 — 끝 24:00 을 그대로 담고 Prisma 의 TIME→DateTime 변환을 피한다(자체 결정).
--      기간은 2년 이하(서버 계산량 상한). 하루를 넘는 블록(끝 < 시작)은 만들지 않는다.
--   ② RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·UPDATE·DELETE — 삭제는 영구), anon·authenticated·PUBLIC 회수, 끝 검사.
-- 안전성: 새 테이블 하나만 만든다. 기존 테이블·행은 바꾸지 않는다.
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 새 함수는 만들지 않는다(updated_at 은 V1 의 set_updated_at 재사용). flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① room_blocks: 연습실 시간 막기 ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS room_blocks (
    id             UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    -- 팀 캘린더에 보이는 글자(예: 고정 사용) — 팀 이름은 넣지 않는다
    title          VARCHAR(30)   NOT NULL,
    -- 관리자만 보는 메모
    memo           VARCHAR(200)  NULL,
    -- NONE = 하루만, WEEKLY = 매주 weekdays 요일
    repeat         VARCHAR(10)   NOT NULL,
    -- ISO 요일 1(월)~7(일). WEEKLY 는 1개 이상, NONE 은 빈 배열
    weekdays       SMALLINT[]    NOT NULL DEFAULT '{}',
    -- KST 하루 안 분(0~1440). 끝 1440 = 24:00
    start_minutes  SMALLINT      NOT NULL,
    end_minutes    SMALLINT      NOT NULL,
    -- KST 날짜. NONE 이면 start_date = end_date
    start_date     DATE          NOT NULL,
    end_date       DATE          NOT NULL,
    -- 이 날만 해제(KST 날짜)
    skip_dates     DATE[]        NOT NULL DEFAULT '{}',
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_room_blocks_title CHECK (char_length(btrim(title)) BETWEEN 1 AND 30),
    CONSTRAINT ck_room_blocks_memo_not_blank CHECK (memo IS NULL OR char_length(btrim(memo)) > 0),
    CONSTRAINT ck_room_blocks_repeat CHECK (repeat IN ('NONE', 'WEEKLY')),
    CONSTRAINT ck_room_blocks_weekdays CHECK (
        weekdays <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::SMALLINT[]
        AND (
            (repeat = 'WEEKLY' AND cardinality(weekdays) BETWEEN 1 AND 7)
            OR (repeat = 'NONE' AND cardinality(weekdays) = 0)
        )
    ),
    -- 30분 단위, 30분~하루
    CONSTRAINT ck_room_blocks_minutes CHECK (
        start_minutes >= 0 AND end_minutes <= 1440
        AND start_minutes % 30 = 0 AND end_minutes % 30 = 0
        AND end_minutes - start_minutes >= 30
    ),
    CONSTRAINT ck_room_blocks_dates CHECK (
        end_date >= start_date
        AND end_date - start_date <= 731
        AND (repeat = 'WEEKLY' OR end_date = start_date)
    )
);
-- 기간 조회(캘린더·예약 판정 — start_date <= 끝 AND end_date >= 시작)
CREATE INDEX IF NOT EXISTS idx_room_blocks_end_date_start_date ON room_blocks (end_date, start_date);
CREATE OR REPLACE TRIGGER trg_room_blocks_updated_at
    BEFORE UPDATE ON room_blocks FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ② 권한 · RLS ─────────────────────────────────────────────────────
-- 관리(추가·수정·이 날만 해제·삭제 — 삭제는 영구, 발생분이 즉시 사라진다) + 팀 예약 판정(조회)
GRANT SELECT, INSERT, UPDATE, DELETE ON room_blocks TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['room_blocks'];
    t text;
    r text;
BEGIN
    FOREACH t IN ARRAY new_tables LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
             WHERE schemaname = 'public' AND tablename = t AND policyname = 'sam_app_all'
        ) THEN
            EXECUTE format(
                'CREATE POLICY sam_app_all ON public.%I AS PERMISSIVE FOR ALL TO sam_app USING (true) WITH CHECK (true)',
                t
            );
        END IF;
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC', t);
        FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF to_regrole(r) IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
            END IF;
        END LOOP;
    END LOOP;
END
$$;

-- ── ③ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
-- 아래 begin·end 표시 사이는 scripts/check-security.sql 과 같은 식이어야 한다
-- (db 테스트 scripts/check-security.test.mjs 가 check:begin 이 있는 모든 마이그레이션을 공백 정규화해 비교한다).
DO $$
DECLARE
    violation_count integer;
    violation_list  text;
BEGIN
    WITH
-- check:begin
    target_roles AS (
        SELECT rolname::text AS role_name FROM pg_roles WHERE rolname IN ('anon', 'authenticated')
        UNION ALL SELECT 'public'
    ),
    relation_privileges AS (
        SELECT 'relation' AS kind, c.relname::text AS object_name, t.role_name, p.privilege
          FROM pg_class c
          CROSS JOIN target_roles t
          CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(privilege)
         WHERE c.relnamespace = 'public'::regnamespace
           AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
           AND (has_table_privilege(t.role_name, c.oid, p.privilege)
                OR (p.privilege IN ('SELECT', 'INSERT', 'UPDATE', 'REFERENCES')
                    AND has_any_column_privilege(t.role_name, c.oid, p.privilege)))
    ),
    sequence_privileges AS (
        SELECT 'sequence', c.relname::text, t.role_name, p.privilege
          FROM pg_class c
          CROSS JOIN target_roles t
          CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) AS p(privilege)
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
           AND has_sequence_privilege(t.role_name, c.oid, p.privilege)
    ),
    function_privileges AS (
        SELECT 'function', p.oid::regprocedure::text, t.role_name, 'EXECUTE'
          FROM pg_proc p
          CROSS JOIN target_roles t
         WHERE p.pronamespace = 'public'::regnamespace
           AND has_function_privilege(t.role_name, p.oid, 'EXECUTE')
    ),
    schema_privileges AS (
        SELECT 'schema', 'public', g.rolname::text, a.privilege_type
          FROM pg_namespace n
          CROSS JOIN LATERAL aclexplode(n.nspacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE n.nspname = 'public'
           AND g.rolname IN ('anon', 'authenticated')
        UNION
        SELECT 'schema', 'public', t.role_name, 'CREATE'
          FROM target_roles t
         WHERE has_schema_privilege(t.role_name, 'public', 'CREATE')
    ),
    default_privileges AS (
        SELECT 'default_acl', pg_get_userbyid(d.defaclrole) || ':' || d.defaclobjtype::text, g.rolname::text, a.privilege_type
          FROM pg_default_acl d
          CROSS JOIN LATERAL aclexplode(d.defaclacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE (d.defaclnamespace = 'public'::regnamespace OR d.defaclnamespace = 0)
           AND g.rolname IN ('anon', 'authenticated')
           AND (d.defaclrole = current_user::regrole
                OR d.defaclrole IN (SELECT c.relowner FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace))
    ),
    rls_disabled AS (
        SELECT 'rls_disabled', c.relname::text, '-', 'ROW LEVEL SECURITY'
          FROM pg_class c
         WHERE c.relnamespace = 'public'::regnamespace
           AND c.relkind IN ('r', 'p')
           AND c.relname <> 'flyway_schema_history'
           AND NOT c.relrowsecurity
    ),
    policy_to_supabase_roles AS (
        SELECT 'policy', p.tablename::text || '.' || p.policyname::text, r.role_name::text, p.cmd::text
          FROM pg_policies p
          CROSS JOIN LATERAL unnest(p.roles) AS r(role_name)
         WHERE p.schemaname = 'public'
           AND r.role_name IN ('anon', 'authenticated', 'public')
    ),
    violations AS (
        SELECT * FROM relation_privileges
        UNION ALL SELECT * FROM sequence_privileges
        UNION ALL SELECT * FROM function_privileges
        UNION ALL SELECT * FROM schema_privileges
        UNION ALL SELECT * FROM default_privileges
        UNION ALL SELECT * FROM rls_disabled
        UNION ALL SELECT * FROM policy_to_supabase_roles
    )
-- check:end
    SELECT count(*), string_agg(kind || ':' || object_name || ':' || role_name || ':' || privilege, ', ')
      INTO violation_count, violation_list
      FROM violations;

    IF violation_count > 0 THEN
        RAISE EXCEPTION 'V1_0_16 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
