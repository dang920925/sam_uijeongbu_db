-- ----------------------------------------------------------------------
-- V1_0_11(임시 번호 — 배포 때 release-manager 가 빈 번호로 바꾼다, 기획 §22.3): 대시보드 새 예매 푸시 구독(U37)
-- 배경: 공개 예매가 들어올 때마다 관리자 휴대폰·PC 에 푸시 알림을 보낸다(사용자 U37, 2026-11-20 — "예매한 사람 있을 때마다
--       푸시 알림까지 하고 싶은데, 돈 들어왔는지 확인은 직접 하더라도"). 정본: 기획 develop §21(계약 확정본) · project-manager.md §26.
-- 범위:
--   ① push_subscriptions(신규) — 관리자 계정 × 기기(브라우저) 1행. Web Push 구독(endpoint + p256dh·auth 키)과
--      기기 이름 표시용 user_agent, 마지막 발송 성공 시각. endpoint 는 전역 유일(같은 기기가 다시 등록하면 서버가 갱신).
--      관리자 계정을 지우면 그 기기 구독도 함께 지운다(CASCADE). 푸시 서비스가 410/404 를 주면 서버가 그 행을 지운다.
--      이름·연락처 같은 개인정보는 이 표에 없다(알림 본문은 저장하지 않는다 — develop J-108).
--   ② RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·UPDATE·DELETE), anon·authenticated·PUBLIC 회수, 끝 검사(V1_0_4 와 같은 식).
-- 안전성: 새 테이블 하나만 만든다 — 기존 테이블·행을 바꾸지 않는다. admins 만 FK 로 참조한다.
--   - 다른 미배포 트랙(T-SA·T-PR·T-SEAT·T-R2·T-R3)의 테이블·컬럼을 참조하지 않는다(develop J-96).
--   - 모든 객체는 IF NOT EXISTS / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① push_subscriptions: 관리자 기기별 푸시 구독 (develop §21) ─────────
CREATE TABLE IF NOT EXISTS push_subscriptions (
    id              UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id        UUID          NOT NULL REFERENCES admins (id) ON DELETE CASCADE,
    -- 푸시 서비스 주소(브라우저가 정함). https 만 받는다(서버 검증과 이중 방어)
    endpoint        VARCHAR(1000) NOT NULL,
    -- 구독 공개키(base64url)·인증 비밀(base64url) — 알림 암호화용(RFC 8291)
    p256dh          VARCHAR(200)  NOT NULL,
    auth            VARCHAR(100)  NOT NULL,
    -- 기기 이름 표시용(SCR-D15 기기 목록). 브라우저가 보낸 값을 200자로 자른다
    user_agent      VARCHAR(200)  NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now(),
    last_success_at TIMESTAMPTZ   NULL,
    CONSTRAINT uq_push_subscriptions_endpoint UNIQUE (endpoint),
    CONSTRAINT ck_push_subscriptions_endpoint_https CHECK (endpoint LIKE 'https://%'),
    CONSTRAINT ck_push_subscriptions_keys_not_blank CHECK (char_length(p256dh) > 0 AND char_length(auth) > 0)
);
-- FK 인덱스 + "내 기기 목록"(admin_id 로 최근 등록 순)·"이 계정 전체에 시험 발송"
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_admin_id_created_at ON push_subscriptions (admin_id, created_at);

-- ── ② 권한 · RLS ─────────────────────────────────────────────────────
-- 등록·갱신(같은 endpoint)·발송 성공 시각 기록·해지·410 정리
GRANT SELECT, INSERT, UPDATE, DELETE ON push_subscriptions TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['push_subscriptions'];
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
        -- Supabase 기본 권한이 새 테이블에 붙었을 수 있다 — 테이블 단위로 다시 회수한다(V1_0_2 ③ 과 같은 대상)
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
        RAISE EXCEPTION 'V1_0_11 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
