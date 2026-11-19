-- ----------------------------------------------------------------------
-- V1_0_2: RLS 켜기 + anon·authenticated·PUBLIC 권한 회수 + 끝 검사 (마지막 보안 단계)
-- 배경: Supabase 는 public 스키마의 새 테이블에 anon·authenticated 기본 권한을 줄 수 있고(Data API 노출 위험 R8),
--       "Enable RLS on every table in an exposed schema" 를 권한다. 이 서비스는 서버만 DB 에 붙고(Data API 끔)
--       브라우저에 Supabase 키가 없다(develop §7.2). 그래도 키 유출·설정 실수에 대비해 DB 가 직접 막는다.
--       (가이드 A17.1 "최소 권한(DB — 브라우저에 데이터 API 키가 있을 때)", develop §4 보안,
--        https://supabase.com/docs/guides/database/postgres/row-level-security ,
--        https://supabase.com/docs/guides/api/securing-your-api )
-- 범위: ① public 의 모든 앱 테이블에 ROW LEVEL SECURITY 를 켠다.
--          ⚠ 2026-11-19 실측: flyway_schema_history 에 ALTER TABLE … ENABLE RLS 를 넣으면 Flyway 가 다른 연결로 잡은
--          이력 테이블 잠금을 기다리며 멈춘다(교착). 그래서 이 테이블은 RLS 대상에서 빼고(검사에서도 제외) 권한 회수(③)로만
--          막는다. Supabase Security Advisor 경고를 없애려면 마이그레이션 뒤 SQL Editor 에서 한 번
--          `ALTER TABLE public.flyway_schema_history ENABLE ROW LEVEL SECURITY;` 를 실행한다(db README).
--       ② 런타임 역할 sam_app 에만 "모든 행" 정책을 준다(권한 범위는 V1_0_1 GRANT 가 정한다).
--          anon·authenticated 에는 정책이 없으므로 권한이 남아 있어도 0행이다(이중 방어).
--          테이블 소유자(마이그레이션 계정)는 RLS 를 우회한다 — 관리자 생성 스크립트·Flyway 용.
--       ③ anon·authenticated(있을 때만 — 로컬 Postgres 에는 없다)·PUBLIC 의 public 테이블·시퀀스·함수·스키마 권한과
--          이 계정의 기본 권한(ALTER DEFAULT PRIVILEGES)을 회수한다.
--       ④ 끝 검사: scripts/check-security.sql 과 같은 식으로 위반을 세고 1건이라도 있으면 예외 → 이 마이그레이션 전체 롤백.
-- 안전성: ENABLE RLS·REVOKE 는 반복 실행해도 같은 결과, 정책은 없을 때만 만든다(멱등).
--         sam_app 이 실제로 쓰는 경로는 정책이 그대로 열어 두므로 API 동작은 바뀌지 않는다(E2E 로 확인).
--         테이블을 새로 추가하는 마이그레이션은 같은 파일에서 RLS·정책·GRANT 를 함께 넣는다(끝 검사가 놓치지 않게 db AGENTS.md 규칙).
-- ----------------------------------------------------------------------

-- ── ① RLS 켜기 ② sam_app 정책 ──────────────────────────────────────────
DO $$
DECLARE
    app_tables CONSTANT text[] := ARRAY[
        'admins', 'performances', 'performance_detail_images', 'classes', 'class_days', 'shows',
        'members', 'actor_profiles', 'actor_filmographies', 'applications', 'galleries',
        'schedules', 'staff', 'popups'
    ];
    t text;
BEGIN
    FOREACH t IN ARRAY app_tables LOOP
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
    END LOOP;
END
$$;

-- ── ③ 권한 회수 ─────────────────────────────────────────────────────────
-- PUBLIC(모든 역할이 상속): 함수 EXECUTE 기본값과 스키마 CREATE 를 회수한다.
-- 트리거 함수는 실행 때 EXECUTE 권한을 보지 않으므로 sam_app 에 다시 줄 필요가 없다.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Supabase 역할(anon · authenticated): 클러스터에 있을 때만
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF to_regrole(r) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', r);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', r);
            EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM %I', r);
            EXECUTE format('REVOKE ALL ON SCHEMA public FROM %I', r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM %I', r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM %I', r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM %I', r);
        END IF;
    END LOOP;
END
$$;

-- ── ④ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
-- 아래 begin·end 표시 사이는 scripts/check-security.sql 과 같은 식이어야 한다
-- (db 테스트 scripts/check-security.test.mjs 가 공백을 정규화해 비교한다).
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
        RAISE EXCEPTION 'V1_0_2 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
