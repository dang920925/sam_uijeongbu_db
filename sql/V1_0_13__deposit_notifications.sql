-- ----------------------------------------------------------------------
-- V1_0_13(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다, 기획 §22.3 · develop J-96):
--   입금 알림 원문 + 자동 입금 확인 판정 (R2 — U24 2단계, FN-38·39, 사용자 결정 2026-11-23)
-- 배경: 관리자 안드로이드 폰의 MacroDroid 가 카카오뱅크·카카오페이(또는 알림톡) 입금 알림의 제목·내용을 웹훅으로 보낸다.
--       서버는 알림 문구 형식을 모르는 채로 금액(잔액 제외)과 입금 대기 예매의 입금자명·예매번호 포함 여부로 판정한다.
--       정본: develop §11.2 R2 · §11.6 + 사용자 결정(2026-11-23 — 경로·헤더·판정표·DEPOSIT_AUTO_CONFIRM 기본 true 가 정본보다 우선).
-- 범위:
--   ① deposit_notifications(신규) — 알림 1건 = 1행. 잔액 부분을 지운 본문(J-51 최소 수집), 해석 금액, 판정 상태·이유,
--      연결된 예매, 멱등 키(내용 해시 + 분 단위 — 같은 원문이 짧은 시간에 두 번 오면 한 번만), 관리자 처리 기록.
--      받은 금액(일부 입금)은 컬럼을 두지 않고 연결된 알림의 금액 합으로 계산한다(파생값).
--      허용 목록 밖 앱(DEPOSIT_ALLOWED_PACKAGES)·'입금' 없는 카카오톡 알림은 저장만 하고 판정하지 않는다(IGNORED_SOURCE).
--      예매가 보유기간으로 파기되면 연결된 알림도 함께 지운다(CASCADE). 연결 안 된 알림은 일일 작업이 30일 뒤 지운다(서버).
--   ② 원문 불변 트리거 — 받은 시각·출처·제목·본문·금액·해시는 바꿀 수 없다(판정 상태·연결·처리 기록만 바뀐다).
--   ③ RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·UPDATE·DELETE), anon·authenticated·PUBLIC 회수, 끝 검사(V1_0_7 과 같은 식).
-- 안전성: 새 테이블 하나 + 그 테이블 트리거만 만든다 — 기존 테이블·행을 바꾸지 않는다. reservations·admins 만 FK 로 참조한다.
--   - 다른 미배포 트랙(v1.3.1 V1_0_12 등)의 테이블·컬럼을 참조하지 않는다(develop J-96).
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① deposit_notifications: 입금 알림 원문과 판정 ────────────────────
CREATE TABLE IF NOT EXISTS deposit_notifications (
    id                UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    -- 서버가 받은 시각(멱등 분 단위·보유기간 기준)
    received_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- 폰이 보낸 알림 시각(형식이 맞을 때만)
    posted_at         TIMESTAMPTZ   NULL,
    -- 알림을 보낸 앱 — MacroDroid 가 보낸 값(source: 자유 문자열 · app_package: 패키지 이름 · app_name: 앱 이름)
    source            VARCHAR(100)  NULL,
    app_package       VARCHAR(100)  NULL,
    app_name          VARCHAR(100)  NULL,
    title             VARCHAR(200)  NULL,
    -- 잔액 숫자를 지운 본문(J-51)
    body_redacted     VARCHAR(1000) NULL,
    -- 해석한 입금 금액(원). 읽지 못하면 NULL
    parsed_amount     INTEGER       NULL,
    status            VARCHAR(20)   NOT NULL,
    review_reason     VARCHAR(30)   NULL,
    -- 판정이 가리킨 예매(자동 확정·일부 입금·확인 필요 후보·관리자 연결)
    reservation_id    UUID          NULL REFERENCES reservations (id) ON DELETE CASCADE,
    -- sha256(출처·제목·본문) — 바로 앞 분의 같은 원문 찾기
    content_hash      CHAR(64)      NOT NULL,
    -- sha256(내용 해시 + 받은 분) — 같은 분 안의 중복을 DB 가 막는다
    dedupe_key        CHAR(64)      NOT NULL,
    resolved_admin_id UUID          NULL REFERENCES admins (id) ON DELETE SET NULL,
    resolved_at       TIMESTAMPTZ   NULL,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT uq_deposit_notifications_dedupe_key UNIQUE (dedupe_key),
    CONSTRAINT ck_deposit_notifications_status CHECK (
        status IN ('AUTO_CONFIRMED', 'PARTIAL', 'NEEDS_REVIEW', 'UNMATCHED', 'MANUALLY_MATCHED', 'IGNORED', 'IGNORED_SOURCE')
    ),
    CONSTRAINT ck_deposit_notifications_review_reason CHECK (
        review_reason IS NULL
        OR review_reason IN ('MULTIPLE_MATCH', 'OVERPAID', 'AMOUNT_UNREADABLE', 'AUTO_CONFIRM_OFF', 'NOT_PENDING')
    ),
    -- 확인 필요만 이유를 가진다
    CONSTRAINT ck_deposit_notifications_reason_pair CHECK ((status = 'NEEDS_REVIEW') = (review_reason IS NOT NULL)),
    CONSTRAINT ck_deposit_notifications_amount_positive CHECK (parsed_amount IS NULL OR parsed_amount > 0),
    -- 확정·일부 입금·관리자 연결은 예매가 있어야 한다. 확인 안 된 입금(UNMATCHED)은 예매가 없다
    CONSTRAINT ck_deposit_notifications_reservation_pair CHECK (
        (status NOT IN ('AUTO_CONFIRMED', 'PARTIAL', 'MANUALLY_MATCHED') OR reservation_id IS NOT NULL)
        AND (status NOT IN ('UNMATCHED', 'IGNORED_SOURCE') OR reservation_id IS NULL)
    ),
    -- 일부 입금은 금액을 안다
    CONSTRAINT ck_deposit_notifications_partial_amount CHECK (status <> 'PARTIAL' OR parsed_amount IS NOT NULL),
    -- 관리자 처리(연결·무시)는 처리 시각이 있다
    CONSTRAINT ck_deposit_notifications_resolved CHECK (
        status NOT IN ('MANUALLY_MATCHED', 'IGNORED') OR resolved_at IS NOT NULL
    )
);
-- 목록(상태별 최신순) · FK 인덱스 · 바로 앞 분 같은 원문 찾기 · 보유기간 파기(연결 안 된 알림)
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_status_received_at ON deposit_notifications (status, received_at);
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_reservation_id ON deposit_notifications (reservation_id);
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_resolved_admin_id ON deposit_notifications (resolved_admin_id);
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_content_hash_received_at ON deposit_notifications (content_hash, received_at);
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_received_at ON deposit_notifications (received_at);

CREATE OR REPLACE TRIGGER trg_deposit_notifications_updated_at
    BEFORE UPDATE ON deposit_notifications FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ② 원문 불변 트리거 ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION deposit_notifications_guard_update() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.received_at IS DISTINCT FROM OLD.received_at
       OR NEW.posted_at IS DISTINCT FROM OLD.posted_at
       OR NEW.source IS DISTINCT FROM OLD.source
       OR NEW.app_package IS DISTINCT FROM OLD.app_package
       OR NEW.app_name IS DISTINCT FROM OLD.app_name
       OR NEW.title IS DISTINCT FROM OLD.title
       OR NEW.body_redacted IS DISTINCT FROM OLD.body_redacted
       OR NEW.parsed_amount IS DISTINCT FROM OLD.parsed_amount
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.dedupe_key IS DISTINCT FROM OLD.dedupe_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION '입금 알림 원문은 바꿀 수 없습니다(판정 상태·연결·처리 기록만 바뀝니다)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE TRIGGER trg_deposit_notifications_guard_update
    BEFORE UPDATE ON deposit_notifications FOR EACH ROW EXECUTE FUNCTION deposit_notifications_guard_update();

-- ── ③ 권한 · RLS ─────────────────────────────────────────────────────
-- 받기(INSERT)·판정 갱신·관리자 연결/무시(UPDATE)·연결 안 된 알림 보유기간 파기(DELETE — 일일 작업)
GRANT SELECT, INSERT, UPDATE, DELETE ON deposit_notifications TO sam_app;

DO $$
DECLARE
    r text;
BEGIN
    REVOKE ALL ON FUNCTION deposit_notifications_guard_update() FROM PUBLIC;
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF to_regrole(r) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON FUNCTION public.deposit_notifications_guard_update() FROM %I', r);
        END IF;
    END LOOP;
END
$$;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['deposit_notifications'];
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

-- ── ④ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
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
        RAISE EXCEPTION 'V1_0_13 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
