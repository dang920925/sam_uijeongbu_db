-- ----------------------------------------------------------------------
-- V1_0_14(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다): 입금 알림 기기 등록 (U43 — 사용자 결정 2026-11-23)
-- 배경: 입금 알림 앱(SAM 의정부 관리)에 웹훅 비밀값을 손으로 붙여 넣던 방식을, 대시보드 버튼으로 기기를 등록하는 방식으로 바꾼다.
--       대시보드가 기기 토큰(256비트 무작위)을 발급받아 앱으로 넘기고, 앱은 Authorization: Bearer <토큰> 으로 웹훅을 보낸다.
--       기존 X-Deposit-Secret(MacroDroid 대안)은 그대로 둔다(서버 가드가 둘 중 하나를 받는다).
-- 범위:
--   ① deposit_devices(신규) — 기기 1대 = 1행. 이름, 토큰 SHA-256 해시(평문은 저장하지 않음 · UNIQUE), 등록 관리자,
--      마지막 수신 시각, 해제 시각(해제해도 행은 남겨 알림의 '보낸 기기' 이름을 유지한다). 해제되지 않은 기기 상한 5대는 서버가 센다.
--   ② deposit_notifications.device_id(신규 NULL 컬럼) — 기기 토큰으로 받은 알림의 보낸 기기. 비밀값(MacroDroid)으로 받으면 NULL.
--      FK ON DELETE SET NULL(기기 행은 지우지 않지만 지워져도 알림은 남는다) + 인덱스. 원문 불변 트리거에 device_id 를 더한다.
--   ③ RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·UPDATE — 해제는 UPDATE, DELETE 없음), anon·authenticated·PUBLIC 회수, 끝 검사.
-- 안전성: 새 테이블 하나 + 기존 deposit_notifications 에 NULL 허용 컬럼 하나(기존 행은 NULL — 바꾸지 않음) + 트리거 함수 교체.
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① deposit_devices: 입금 알림 기기 ─────────────────────────────────
CREATE TABLE IF NOT EXISTS deposit_devices (
    id            UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    -- 관리자가 붙인 이름(예: 관리자 폰)
    name          VARCHAR(40)   NOT NULL,
    -- sha256(기기 토큰) 16진수 — 평문 토큰은 발급 응답에서 한 번만 내보내고 저장하지 않는다
    token_hash    CHAR(64)      NOT NULL,
    -- 등록한 관리자(계정이 지워져도 기기는 남는다)
    created_by    UUID          NULL REFERENCES admins (id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- 마지막으로 이 기기 토큰으로 알림을 받은 시각
    last_seen_at  TIMESTAMPTZ   NULL,
    -- 해제 시각 — 값이 있으면 이 토큰은 더 이상 통과하지 않는다
    revoked_at    TIMESTAMPTZ   NULL,
    CONSTRAINT uq_deposit_devices_token_hash UNIQUE (token_hash),
    CONSTRAINT ck_deposit_devices_name CHECK (char_length(btrim(name)) BETWEEN 1 AND 40),
    CONSTRAINT ck_deposit_devices_token_hash CHECK (token_hash ~ '^[0-9a-f]{64}$')
);
-- FK 인덱스 · 목록(해제 안 된 기기 등록 순)
CREATE INDEX IF NOT EXISTS idx_deposit_devices_created_by ON deposit_devices (created_by);
CREATE INDEX IF NOT EXISTS idx_deposit_devices_revoked_at_created_at ON deposit_devices (revoked_at, created_at);

-- ── ② deposit_notifications.device_id: 보낸 기기 ──────────────────────
ALTER TABLE deposit_notifications
    ADD COLUMN IF NOT EXISTS device_id UUID NULL REFERENCES deposit_devices (id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_deposit_notifications_device_id ON deposit_notifications (device_id);

-- 원문 불변 트리거 함수 교체 — 보낸 기기(device_id)도 원문이다
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
       OR NEW.device_id IS DISTINCT FROM OLD.device_id
       OR NEW.content_hash IS DISTINCT FROM OLD.content_hash
       OR NEW.dedupe_key IS DISTINCT FROM OLD.dedupe_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION '입금 알림 원문은 바꿀 수 없습니다(판정 상태·연결·처리 기록만 바뀝니다)'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

-- ── ③ 권한 · RLS ─────────────────────────────────────────────────────
-- 등록(INSERT)·목록(SELECT)·해제와 마지막 수신 시각(UPDATE). 행은 지우지 않는다(알림의 보낸 기기 이름 유지)
GRANT SELECT, INSERT, UPDATE ON deposit_devices TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['deposit_devices'];
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
    -- 함수 교체(CREATE OR REPLACE)는 기존 권한을 유지하지만 다시 회수해 둔다
    REVOKE ALL ON FUNCTION deposit_notifications_guard_update() FROM PUBLIC;
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF to_regrole(r) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON FUNCTION public.deposit_notifications_guard_update() FROM %I', r);
        END IF;
    END LOOP;
END
$$;

-- ── ⑤ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
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
        RAISE EXCEPTION 'V1_0_14 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
