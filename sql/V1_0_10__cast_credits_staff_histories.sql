-- ----------------------------------------------------------------------
-- V1_0_8: 배역·회차별 캐스팅 · 작품 참여자(크레딧) · 캐스트 공개 스위치 · 연출진 연혁 (U26 · U28 · U33, R3)
-- ⚠ 임시 번호(트랙 R3) — 배포 순서대로 release-manager 가 다음 빈 번호로 바꾼다(기획 §22.3, J-96).
-- 배경: 작품 상세에 배역·회차별 캐스트와 참여자(연출·조연출 …)를 보여 주고, 배우·연출진 상세에 SAM 참여 작품을 자동으로
--       묶는다. 개인정보 보호를 위해 작품 단위 공개 스위치(기본 꺼짐)와 크레딧 노출(기본 꺼짐)을 둔다.
--       정본: 기획 develop §11.2 R3 표 · §12.2(연혁) · §17.1(공개 컬럼·크레딧·"출연" 묶음) · §17.5(배우 쪽 연결), J-46·J-86·J-87·J-91.
-- 범위:
--   ① performances.cast_public(기본 false — 캐스트·크레딧 공개 스위치, J-89)
--   ② performance_roles(신규) — name NULL = "출연" 묶음(공연당 1개 — 부분 유니크, J-87)
--   ③ role_casts(신규 — 기본 캐스트, 더블 캐스팅 허용) · ④ show_role_casts(신규 — 회차 지정, J-46)
--      회차와 배역이 같은 공연인지는 서버가 검사한다(400 ROL_003).
--   ⑤ performance_credits(신규) — 직함 자유 글자 · 연출진/단원 중 하나 연결 또는 이름만 · 이름 스냅숏(display_name)
--   ⑥ staff_histories(신규 — 연출진 연혁, actor_filmographies 와 같은 모양)
--   ⑦ 새 테이블 5개 RLS + sam_app_all 정책 + GRANT, anon·authenticated·PUBLIC 권한 회수, 끝 검사(V1_0_4 와 같은 식).
-- 안전성: 기존 테이블 변경은 performances 에 기본값 있는 컬럼 하나 추가뿐(기존 행은 false = 비공개로 시작 — 보이는 변화 없음).
--   - 새 테이블만 만든다. 기존 행을 지우거나 바꾸지 않는다. 운영 데이터 입력은 release-manager 가 관리 API 로 한다(J-88).
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다(V1_0_2 교착 교훈).
-- ----------------------------------------------------------------------

-- ── ① performances.cast_public ────────────────────────────────────────
ALTER TABLE performances ADD COLUMN IF NOT EXISTS cast_public BOOLEAN NOT NULL DEFAULT false;

-- ── ② performance_roles: 배역 (FN-42) — name NULL = "출연" 묶음 ─────────
CREATE TABLE IF NOT EXISTS performance_roles (
    id             UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    name           VARCHAR(50)  NULL,
    description    VARCHAR(500) NULL,
    sort_order     SMALLINT     NOT NULL,
    is_recruiting  BOOLEAN      NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_performance_roles_name_not_blank CHECK (name IS NULL OR char_length(btrim(name)) > 0),
    CONSTRAINT ck_performance_roles_sort_order CHECK (sort_order BETWEEN 0 AND 999)
);
-- (performance_id, sort_order) 인덱스가 FK 인덱스를 겸한다
CREATE INDEX IF NOT EXISTS idx_performance_roles_performance_order ON performance_roles (performance_id, sort_order);
-- "출연" 묶음은 공연당 1개(동시 생성은 서버가 유니크 위반 뒤 다시 조회해 재사용).
-- 식 열 (name IS NULL) 을 넣은 이유: 열 하나짜리 부분 유니크는 Prisma db pull 이 @unique 로 읽어 공연↔배역을 1:1 관계로
-- 만들어 버린다. 식 인덱스는 Prisma 가 모델에 옮기지 않아 1:N 관계가 유지된다(뜻은 같다 — WHERE 로 NULL 행만 대상).
CREATE UNIQUE INDEX IF NOT EXISTS uq_performance_roles_ensemble
    ON performance_roles (performance_id, (name IS NULL)) WHERE name IS NULL;
CREATE OR REPLACE TRIGGER trg_performance_roles_updated_at
    BEFORE UPDATE ON performance_roles FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ③ role_casts: 기본 캐스트 (FN-42, 더블 캐스팅 허용) ────────────────
CREATE TABLE IF NOT EXISTS role_casts (
    id               UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    role_id          UUID        NOT NULL REFERENCES performance_roles (id) ON DELETE CASCADE,
    actor_profile_id UUID        NOT NULL REFERENCES actor_profiles (id) ON DELETE CASCADE,
    note             VARCHAR(30) NULL,
    sort_order       SMALLINT    NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- (role_id, actor_profile_id) 유니크가 role_id FK 인덱스를 겸한다
    CONSTRAINT uq_role_casts_role_actor UNIQUE (role_id, actor_profile_id),
    CONSTRAINT ck_role_casts_sort_order CHECK (sort_order BETWEEN 0 AND 999)
);
CREATE INDEX IF NOT EXISTS idx_role_casts_actor_profile_id ON role_casts (actor_profile_id);

-- ── ④ show_role_casts: 회차 지정 캐스트 (FN-43, J-46) ─────────────────
-- 어떤 (회차, 배역)에 행이 하나라도 있으면 그 행들이 그 회차 캐스트, 없으면 기본 캐스트.
CREATE TABLE IF NOT EXISTS show_role_casts (
    id               UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    show_id          UUID        NOT NULL REFERENCES shows (id) ON DELETE CASCADE,
    role_id          UUID        NOT NULL REFERENCES performance_roles (id) ON DELETE CASCADE,
    actor_profile_id UUID        NOT NULL REFERENCES actor_profiles (id) ON DELETE CASCADE,
    note             VARCHAR(30) NULL,
    sort_order       SMALLINT    NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- (show_id, role_id, actor_profile_id) 유니크가 show_id FK 인덱스를 겸한다
    CONSTRAINT uq_show_role_casts_show_role_actor UNIQUE (show_id, role_id, actor_profile_id),
    CONSTRAINT ck_show_role_casts_sort_order CHECK (sort_order BETWEEN 0 AND 999)
);
CREATE INDEX IF NOT EXISTS idx_show_role_casts_role_id ON show_role_casts (role_id);
CREATE INDEX IF NOT EXISTS idx_show_role_casts_actor_profile_id ON show_role_casts (actor_profile_id);

-- ── ⑤ performance_credits: 작품 참여자(크레딧) (FN-53) ────────────────
-- 연결 대상이 지워지면 SET NULL — 서버가 연결할 때 display_name 에 이름 스냅숏을 항상 함께 저장하므로 CHECK 에 걸리지 않는다(CR-8).
CREATE TABLE IF NOT EXISTS performance_credits (
    id             UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID        NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    title          VARCHAR(30) NOT NULL,
    staff_id       UUID        NULL REFERENCES staff (id) ON DELETE SET NULL,
    member_id      UUID        NULL REFERENCES members (id) ON DELETE SET NULL,
    display_name   VARCHAR(50) NULL,
    sort_order     SMALLINT    NOT NULL DEFAULT 0,
    is_visible     BOOLEAN     NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_performance_credits_title_not_blank CHECK (char_length(btrim(title)) > 0),
    CONSTRAINT ck_performance_credits_display_name_not_blank CHECK (display_name IS NULL OR char_length(btrim(display_name)) > 0),
    CONSTRAINT ck_performance_credits_single_link CHECK (NOT (staff_id IS NOT NULL AND member_id IS NOT NULL)),
    CONSTRAINT ck_performance_credits_has_name CHECK (staff_id IS NOT NULL OR member_id IS NOT NULL OR display_name IS NOT NULL),
    CONSTRAINT ck_performance_credits_sort_order CHECK (sort_order BETWEEN 0 AND 999)
);
CREATE INDEX IF NOT EXISTS idx_performance_credits_performance_order ON performance_credits (performance_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_performance_credits_staff_id ON performance_credits (staff_id);
CREATE INDEX IF NOT EXISTS idx_performance_credits_member_id ON performance_credits (member_id);
CREATE OR REPLACE TRIGGER trg_performance_credits_updated_at
    BEFORE UPDATE ON performance_credits FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ⑥ staff_histories: 연출진 연혁 (FN-46) ────────────────────────────
CREATE TABLE IF NOT EXISTS staff_histories (
    id         UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    staff_id   UUID         NOT NULL REFERENCES staff (id) ON DELETE CASCADE,
    year       SMALLINT     NOT NULL,
    content    VARCHAR(200) NOT NULL,
    sort_order SMALLINT     NOT NULL,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- (staff_id, sort_order) 유니크 인덱스가 FK 인덱스를 겸한다(actor_filmographies 와 같은 모양)
    CONSTRAINT uq_staff_histories_order UNIQUE (staff_id, sort_order),
    CONSTRAINT ck_staff_histories_year CHECK (year BETWEEN 1900 AND 2100),
    CONSTRAINT ck_staff_histories_sort_order CHECK (sort_order BETWEEN 0 AND 99),
    CONSTRAINT ck_staff_histories_content_not_blank CHECK (char_length(btrim(content)) > 0)
);

-- ── ⑦ 권한 · RLS ─────────────────────────────────────────────────────
-- 배역·캐스팅·크레딧·연혁: 관리 화면이 행 단위로 추가·수정·삭제한다(영구 삭제 — 통째 교체 포함)
GRANT SELECT, INSERT, UPDATE, DELETE ON
    performance_roles, role_casts, show_role_casts, performance_credits, staff_histories
    TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['performance_roles', 'role_casts', 'show_role_casts', 'performance_credits', 'staff_histories'];
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

-- ── ⑧ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
-- 아래 begin·end 표시 사이는 scripts/check-security.sql 과 같은 식이어야 한다(scripts/check-security.test.mjs 가 비교).
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
        RAISE EXCEPTION 'V1_0_8 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
