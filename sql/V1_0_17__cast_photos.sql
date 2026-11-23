-- ----------------------------------------------------------------------
-- V1_0_17: 캐스트 사진(단체샷 · 팀샷 · 배역 개인샷) + 회차 팀 지정 (U48 — 사용자 결정 2026-11-23, 안 A 팀 중심)
-- 배경: 작품 상세 캐스트 영역을 단체샷 → 팀 탭 → 팀샷·출연 회차 → 배역 카드(배역 사진) 순으로 바꾼다(designer §19).
--       회차마다 어느 팀이 나오는지 저장해야 "출연 회차" 칩·NEXT SHOW "A팀 출연"·예매 "이 회차 출연" 표시가 맞는다
--       (회차 칸 캐스트에서 추정하면 두 팀 배우·회차 지정 때문에 틀리기 쉽다).
-- 범위:
--   ① performance_group_photos(신규) — 공연 단체샷 0~4장. sort_order 0~3 CHECK + (공연, 순서) UNIQUE 로 4장 상한을 DB 가 막는다.
--      UNIQUE 는 DEFERRABLE INITIALLY DEFERRED — 순서 바꾸기(한 트랜잭션에서 자리 맞바꿈)가 커밋 때만 검사되게.
--   ② team_accounts.team_photo_url(NULL) — 팀샷 1장.
--   ③ cast_role_photos(신규) — 배역 × 배우(role_casts 와 같은 키 role_id·actor_profile_id) 개인샷. 조합 PK.
--      배역(performance_roles)이나 배우 프로필(actor_profiles)이 지워지면 CASCADE. 기본 캐스트 저장은 role_casts 를
--      지웠다 다시 넣으므로 role_casts 에는 FK 를 걸지 않는다(걸면 캐스트 저장마다 사진이 지워진다).
--   ④ shows.team_account_id(NULL, FK SET NULL) — 회차 팀 지정. 같은 공연의 폐기 안 된 팀만(트리거 shows_guard_team_account).
--      팀이 폐기되면(revoked_at 이 채워지면) 트리거 team_accounts_clear_show_team 이 그 팀을 쓰던 회차를 NULL 로 돌린다.
--   ⑤ RLS + sam_app_all 정책 + GRANT, 새 함수 EXECUTE 회수, anon·authenticated·PUBLIC 회수, 끝 검사.
-- 안전성: 새 테이블 두 개 · 기존 테이블에 NULL 열 두 개(기존 행은 NULL — 동작 변화 없음) · 트리거 두 개.
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 기존 행·데이터는 바꾸지 않는다. flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① performance_group_photos: 공연 단체샷(최대 4장) ──────────────────
CREATE TABLE IF NOT EXISTS performance_group_photos (
    id             UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    image_url      VARCHAR(500) NOT NULL,
    -- 0 = 대표(첫 장). 0~3 이라 공연당 4장을 넘을 수 없다(UNIQUE 와 함께)
    sort_order     SMALLINT     NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_performance_group_photos_url CHECK (image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)'),
    CONSTRAINT ck_performance_group_photos_sort_order CHECK (sort_order BETWEEN 0 AND 3),
    -- (공연, 순서) 유니크가 performance_id FK 인덱스를 겸한다
    CONSTRAINT uq_performance_group_photos_performance_order UNIQUE (performance_id, sort_order)
        DEFERRABLE INITIALLY DEFERRED
);

-- ── ② team_accounts.team_photo_url: 팀샷 ─────────────────────────────
ALTER TABLE team_accounts ADD COLUMN IF NOT EXISTS team_photo_url VARCHAR(500) NULL;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'ck_team_accounts_team_photo_url' AND conrelid = 'public.team_accounts'::regclass
    ) THEN
        ALTER TABLE team_accounts ADD CONSTRAINT ck_team_accounts_team_photo_url
            CHECK (team_photo_url IS NULL OR team_photo_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)');
    END IF;
END
$$;

-- ── ③ cast_role_photos: 배역 × 배우 개인샷 ──────────────────────────
CREATE TABLE IF NOT EXISTS cast_role_photos (
    role_id          UUID         NOT NULL REFERENCES performance_roles (id) ON DELETE CASCADE,
    actor_profile_id UUID         NOT NULL REFERENCES actor_profiles (id) ON DELETE CASCADE,
    image_url        VARCHAR(500) NOT NULL,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_cast_role_photos_url CHECK (image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)'),
    -- role_casts 의 uq_role_casts_role_actor 와 같은 키. 조합 PK 가 role_id FK 인덱스를 겸한다
    CONSTRAINT pk_cast_role_photos PRIMARY KEY (role_id, actor_profile_id)
);
CREATE INDEX IF NOT EXISTS idx_cast_role_photos_actor_profile_id ON cast_role_photos (actor_profile_id);
CREATE OR REPLACE TRIGGER trg_cast_role_photos_updated_at
    BEFORE UPDATE ON cast_role_photos FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ④ shows.team_account_id: 회차 팀 지정 ─────────────────────────────
ALTER TABLE shows ADD COLUMN IF NOT EXISTS team_account_id UUID NULL;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'fk_shows_team_account' AND conrelid = 'public.shows'::regclass
    ) THEN
        -- 팀 계정이 지워지면(작품 하드 삭제 등) 회차는 남고 팀 지정만 비운다
        ALTER TABLE shows ADD CONSTRAINT fk_shows_team_account
            FOREIGN KEY (team_account_id) REFERENCES team_accounts (id) ON DELETE SET NULL;
    END IF;
END
$$;
CREATE INDEX IF NOT EXISTS idx_shows_team_account_id ON shows (team_account_id) WHERE team_account_id IS NOT NULL;

-- 같은 공연의 폐기 안 된 팀만 지정할 수 있다(서버도 SHW_005 로 먼저 막는다)
CREATE OR REPLACE FUNCTION shows_guard_team_account() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.team_account_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM team_accounts t
         WHERE t.id = NEW.team_account_id
           AND t.performance_id = NEW.performance_id
           AND t.revoked_at IS NULL
    ) THEN
        RAISE EXCEPTION '회차에는 같은 공연의 사용 중인 팀만 지정할 수 있습니다'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

CREATE OR REPLACE TRIGGER trg_shows_guard_team_account
    BEFORE INSERT OR UPDATE OF team_account_id, performance_id ON shows
    FOR EACH ROW EXECUTE FUNCTION shows_guard_team_account();

-- 팀이 폐기되면(revoked_at NULL → 값) 그 팀을 쓰던 회차의 팀 지정을 비운다
CREATE OR REPLACE FUNCTION team_accounts_clear_show_team() RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE shows SET team_account_id = NULL WHERE team_account_id = NEW.id;
    RETURN NULL;
END
$$;

CREATE OR REPLACE TRIGGER trg_team_accounts_clear_show_team
    AFTER UPDATE OF revoked_at ON team_accounts
    FOR EACH ROW
    WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
    EXECUTE FUNCTION team_accounts_clear_show_team();

-- ── ⑤ 권한 · RLS ─────────────────────────────────────────────────────
-- 단체샷: 추가·순서 바꾸기·교체(UPDATE)·삭제. 배역 사진: 설정(INSERT·UPDATE — upsert)·삭제
GRANT SELECT, INSERT, UPDATE, DELETE ON performance_group_photos, cast_role_photos TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['performance_group_photos', 'cast_role_photos'];
    new_functions CONSTANT text[] := ARRAY['shows_guard_team_account()', 'team_accounts_clear_show_team()'];
    t text;
    f text;
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
    FOREACH f IN ARRAY new_functions LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', f);
        FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
            IF to_regrole(r) IS NOT NULL THEN
                EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM %I', f, r);
            END IF;
        END LOOP;
    END LOOP;
END
$$;

-- ── ⑥ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
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
        RAISE EXCEPTION 'V1_0_17 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
