-- ----------------------------------------------------------------------
-- V1_0_15(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다): 팀 소속 배우 + 연습실 예약 참석자 (U45 — 사용자 요청 2026-11-23)
-- 배경: 대시보드 배역·캐스팅 탭에서 캐스트 배우마다 소속 팀(그 공연의 팀 계정 A·B…)을 정하고(여러 팀 가능, 기본 미배정),
--       홈페이지 연습실 예약(팀 로그인)에서 그 팀 배우 중 참석자를 체크한다. 배우 이름은 팀 내부 공유용 — 다른 팀·공개 화면에는 없다.
-- 범위:
--   ① team_members(신규) — (팀 계정, 단원) 조합 PK. 팀 계정이 지워지면(작품 하드 삭제) CASCADE, 일일 작업이 팀 계정을 폐기하면
--      서버가 그 팀의 행을 지운다. 단원이 영구 삭제되면 CASCADE. "그 공연 캐스트(기본 캐스트·출연 묶음)인 배우만"은 서버가 검사한다.
--   ② room_reservation_attendees(신규) — (예약, 단원) 조합 PK. 예약이 파기(90일 — J-101)되면 CASCADE. "그 팀 소속 배우만"은 서버가
--      검사한다(400). 지난 예약의 참석 기록은 예약과 같은 보유기간을 따른다.
--   ③ RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·DELETE — 행을 고치지 않고 넣고 지운다), anon·authenticated·PUBLIC 회수, 끝 검사.
-- 안전성: 새 테이블 두 개만 만든다. 기존 테이블·행은 바꾸지 않는다.
--   - 모든 객체는 IF NOT EXISTS / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① team_members: 팀 소속 배우 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_members (
    team_account_id UUID        NOT NULL REFERENCES team_accounts (id) ON DELETE CASCADE,
    member_id       UUID        NOT NULL REFERENCES members (id) ON DELETE CASCADE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 조합 PK 가 team_account_id FK 인덱스를 겸한다
    CONSTRAINT pk_team_members PRIMARY KEY (team_account_id, member_id)
);
CREATE INDEX IF NOT EXISTS idx_team_members_member_id ON team_members (member_id);

-- ── ② room_reservation_attendees: 연습실 예약 참석자 ────────────────────
CREATE TABLE IF NOT EXISTS room_reservation_attendees (
    reservation_id UUID        NOT NULL REFERENCES room_reservations (id) ON DELETE CASCADE,
    member_id      UUID        NOT NULL REFERENCES members (id) ON DELETE CASCADE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- 조합 PK 가 reservation_id FK 인덱스를 겸한다
    CONSTRAINT pk_room_reservation_attendees PRIMARY KEY (reservation_id, member_id)
);
CREATE INDEX IF NOT EXISTS idx_room_reservation_attendees_member_id ON room_reservation_attendees (member_id);

-- ── ③ 권한 · RLS ─────────────────────────────────────────────────────
-- 배정·해제(INSERT·DELETE)와 조회(SELECT). 행 수정은 없다(바꿀 열이 없다)
GRANT SELECT, INSERT, DELETE ON team_members, room_reservation_attendees TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['team_members', 'room_reservation_attendees'];
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
        RAISE EXCEPTION 'V1_0_15 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
