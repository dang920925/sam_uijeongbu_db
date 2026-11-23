-- ----------------------------------------------------------------------
-- V1_0_18: 캐스트 사진 '보이는 비율 + 위치(크롭)' — 비파괴 (U51 — 사용자 결정 2026-11-23, 지휘자 확정 데이터안)
-- 배경: 모바일·PC 카드에서 배역 사진·팀샷이 가운데로만 잘려 얼굴이 빠진다. 원본은 그대로 두고 "보이는 비율 + 초점 + 확대"
--       값만 저장해 홈페이지가 그 값으로 잘라 그린다(designer §21, back-end.md §27).
-- 범위:
--   ① performances.cast_card_ratio — 배역 카드 비율(공연 하나, 카드 그리드를 고르게). '3:4'(기본) · '2:3' · '4:5' · '1:1'.
--   ② cast_role_photos.crop · thumb_crop(보드 썸네일, NULL = crop 을 그대로) · image_width · image_height.
--   ③ performance_group_photos.display_ratio(NULL = 원본 비율) · crop · image_width · image_height.
--   ④ team_accounts.team_photo_ratio(NULL = 원본) · team_photo_crop · team_photo_width · team_photo_height.
--   crop 형식 = jsonb {x, y, zoom} — x·y 초점 중심 %(0~100), zoom 1~3, 키 셋만. NULL = 가운데·zoom 1.
--   비율은 VARCHAR + CHECK(값 그대로 '16:9' 처럼 — API 값과 같게, 변환 없음). 크기는 둘 다 NULL 이거나 둘 다 1~20000(한쪽만 NULL 이면 CHECK 결과가 NULL 이라 통과하므로 IS NOT NULL 을 함께 쓴다).
--   사진 교체 시 crop·크기 초기화는 서버가 한다(비율은 유지 — 사용자 지시).
-- 안전성: 기존 테이블에 열만 추가. cast_card_ratio 는 NOT NULL DEFAULT '3:4'(기존 행 = 지금 화면과 같은 3:4),
--   나머지는 NULL(기존 행 = 지금 동작 — 가운데·원본 비율). 새 테이블·함수·트리거·정책 없음(RLS·GRANT 는 테이블 단위라 그대로).
--   CHECK 식은 함수 없이 CASE 로 순서를 고정한다(숫자가 아닌 값을 numeric 으로 바꾸다 오류 나지 않게 — 위반은 CHECK 위반으로).
--   모든 객체는 IF NOT EXISTS / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과). 기존 행 데이터는 바꾸지 않는다.
-- ----------------------------------------------------------------------

-- ── ① performances.cast_card_ratio ────────────────────────────────────
ALTER TABLE performances ADD COLUMN IF NOT EXISTS cast_card_ratio VARCHAR(4) NOT NULL DEFAULT '3:4';

-- ── ② cast_role_photos: 배역 사진 위치·썸네일 위치·원본 크기 ─────────────
ALTER TABLE cast_role_photos ADD COLUMN IF NOT EXISTS crop         JSONB   NULL;
ALTER TABLE cast_role_photos ADD COLUMN IF NOT EXISTS thumb_crop   JSONB   NULL;
ALTER TABLE cast_role_photos ADD COLUMN IF NOT EXISTS image_width  INTEGER NULL;
ALTER TABLE cast_role_photos ADD COLUMN IF NOT EXISTS image_height INTEGER NULL;

-- ── ③ performance_group_photos: 보이는 비율·위치·원본 크기 ────────────────
ALTER TABLE performance_group_photos ADD COLUMN IF NOT EXISTS display_ratio VARCHAR(4) NULL;
ALTER TABLE performance_group_photos ADD COLUMN IF NOT EXISTS crop          JSONB      NULL;
ALTER TABLE performance_group_photos ADD COLUMN IF NOT EXISTS image_width   INTEGER    NULL;
ALTER TABLE performance_group_photos ADD COLUMN IF NOT EXISTS image_height  INTEGER    NULL;

-- ── ④ team_accounts: 팀샷 보이는 비율·위치·원본 크기 ─────────────────────
ALTER TABLE team_accounts ADD COLUMN IF NOT EXISTS team_photo_ratio  VARCHAR(4) NULL;
ALTER TABLE team_accounts ADD COLUMN IF NOT EXISTS team_photo_crop   JSONB      NULL;
ALTER TABLE team_accounts ADD COLUMN IF NOT EXISTS team_photo_width  INTEGER    NULL;
ALTER TABLE team_accounts ADD COLUMN IF NOT EXISTS team_photo_height INTEGER    NULL;

-- ── ⑤ CHECK — 범위·허용 값(서버 검증 COMMON_001 의 마지막 방어) ─────────────
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_performances_cast_card_ratio' AND conrelid = 'public.performances'::regclass
    ) THEN
        ALTER TABLE performances ADD CONSTRAINT ck_performances_cast_card_ratio
            CHECK (cast_card_ratio IN ('3:4', '2:3', '4:5', '1:1'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_cast_role_photos_crop' AND conrelid = 'public.cast_role_photos'::regclass
    ) THEN
        ALTER TABLE cast_role_photos ADD CONSTRAINT ck_cast_role_photos_crop
            CHECK (crop IS NULL OR CASE
                WHEN jsonb_typeof(crop) IS DISTINCT FROM 'object' THEN false
                WHEN NOT (crop ?& ARRAY['x', 'y', 'zoom']) OR (crop - ARRAY['x', 'y', 'zoom']) <> '{}'::jsonb THEN false
                WHEN jsonb_typeof(crop -> 'x') <> 'number' OR jsonb_typeof(crop -> 'y') <> 'number'
                     OR jsonb_typeof(crop -> 'zoom') <> 'number' THEN false
                ELSE (crop ->> 'x')::numeric BETWEEN 0 AND 100
                     AND (crop ->> 'y')::numeric BETWEEN 0 AND 100
                     AND (crop ->> 'zoom')::numeric BETWEEN 1 AND 3
            END);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_cast_role_photos_thumb_crop' AND conrelid = 'public.cast_role_photos'::regclass
    ) THEN
        ALTER TABLE cast_role_photos ADD CONSTRAINT ck_cast_role_photos_thumb_crop
            CHECK (thumb_crop IS NULL OR CASE
                WHEN jsonb_typeof(thumb_crop) IS DISTINCT FROM 'object' THEN false
                WHEN NOT (thumb_crop ?& ARRAY['x', 'y', 'zoom']) OR (thumb_crop - ARRAY['x', 'y', 'zoom']) <> '{}'::jsonb THEN false
                WHEN jsonb_typeof(thumb_crop -> 'x') <> 'number' OR jsonb_typeof(thumb_crop -> 'y') <> 'number'
                     OR jsonb_typeof(thumb_crop -> 'zoom') <> 'number' THEN false
                ELSE (thumb_crop ->> 'x')::numeric BETWEEN 0 AND 100
                     AND (thumb_crop ->> 'y')::numeric BETWEEN 0 AND 100
                     AND (thumb_crop ->> 'zoom')::numeric BETWEEN 1 AND 3
            END);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_cast_role_photos_image_size' AND conrelid = 'public.cast_role_photos'::regclass
    ) THEN
        ALTER TABLE cast_role_photos ADD CONSTRAINT ck_cast_role_photos_image_size
            CHECK ((image_width IS NULL AND image_height IS NULL) OR (image_width IS NOT NULL AND image_height IS NOT NULL AND image_width BETWEEN 1 AND 20000 AND image_height BETWEEN 1 AND 20000));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_performance_group_photos_display_ratio' AND conrelid = 'public.performance_group_photos'::regclass
    ) THEN
        ALTER TABLE performance_group_photos ADD CONSTRAINT ck_performance_group_photos_display_ratio
            CHECK (display_ratio IS NULL OR display_ratio IN ('16:9', '4:3', '1:1', '3:4'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_performance_group_photos_crop' AND conrelid = 'public.performance_group_photos'::regclass
    ) THEN
        ALTER TABLE performance_group_photos ADD CONSTRAINT ck_performance_group_photos_crop
            CHECK (crop IS NULL OR CASE
                WHEN jsonb_typeof(crop) IS DISTINCT FROM 'object' THEN false
                WHEN NOT (crop ?& ARRAY['x', 'y', 'zoom']) OR (crop - ARRAY['x', 'y', 'zoom']) <> '{}'::jsonb THEN false
                WHEN jsonb_typeof(crop -> 'x') <> 'number' OR jsonb_typeof(crop -> 'y') <> 'number'
                     OR jsonb_typeof(crop -> 'zoom') <> 'number' THEN false
                ELSE (crop ->> 'x')::numeric BETWEEN 0 AND 100
                     AND (crop ->> 'y')::numeric BETWEEN 0 AND 100
                     AND (crop ->> 'zoom')::numeric BETWEEN 1 AND 3
            END);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_performance_group_photos_image_size' AND conrelid = 'public.performance_group_photos'::regclass
    ) THEN
        ALTER TABLE performance_group_photos ADD CONSTRAINT ck_performance_group_photos_image_size
            CHECK ((image_width IS NULL AND image_height IS NULL) OR (image_width IS NOT NULL AND image_height IS NOT NULL AND image_width BETWEEN 1 AND 20000 AND image_height BETWEEN 1 AND 20000));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_team_accounts_team_photo_ratio' AND conrelid = 'public.team_accounts'::regclass
    ) THEN
        ALTER TABLE team_accounts ADD CONSTRAINT ck_team_accounts_team_photo_ratio
            CHECK (team_photo_ratio IS NULL OR team_photo_ratio IN ('16:9', '4:3', '1:1', '3:4'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_team_accounts_team_photo_crop' AND conrelid = 'public.team_accounts'::regclass
    ) THEN
        ALTER TABLE team_accounts ADD CONSTRAINT ck_team_accounts_team_photo_crop
            CHECK (team_photo_crop IS NULL OR CASE
                WHEN jsonb_typeof(team_photo_crop) IS DISTINCT FROM 'object' THEN false
                WHEN NOT (team_photo_crop ?& ARRAY['x', 'y', 'zoom']) OR (team_photo_crop - ARRAY['x', 'y', 'zoom']) <> '{}'::jsonb THEN false
                WHEN jsonb_typeof(team_photo_crop -> 'x') <> 'number' OR jsonb_typeof(team_photo_crop -> 'y') <> 'number'
                     OR jsonb_typeof(team_photo_crop -> 'zoom') <> 'number' THEN false
                ELSE (team_photo_crop ->> 'x')::numeric BETWEEN 0 AND 100
                     AND (team_photo_crop ->> 'y')::numeric BETWEEN 0 AND 100
                     AND (team_photo_crop ->> 'zoom')::numeric BETWEEN 1 AND 3
            END);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'ck_team_accounts_team_photo_size' AND conrelid = 'public.team_accounts'::regclass
    ) THEN
        ALTER TABLE team_accounts ADD CONSTRAINT ck_team_accounts_team_photo_size
            CHECK ((team_photo_width IS NULL AND team_photo_height IS NULL) OR (team_photo_width IS NOT NULL AND team_photo_height IS NOT NULL AND team_photo_width BETWEEN 1 AND 20000 AND team_photo_height BETWEEN 1 AND 20000));
    END IF;
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
        RAISE EXCEPTION 'V1_0_18 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
