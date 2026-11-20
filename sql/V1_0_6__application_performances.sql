-- ----------------------------------------------------------------------
-- V1_0_7(임시 번호 — 배포 때 release-manager 가 다음 빈 번호로 바꾼다, 기획 §22.3 · develop J-96):
--   신청 관심 작품 · 연락 여부 · 진행 단계 (U31 + 보강 + 수정, FN-51, 트랙 T-SA)
-- 배경: 상담 신청에 "참가 희망 작품"(복수)·"아직 모르겠어요"를, 참관 신청에 선택 "관심 작품"을 받고(기획 §19·§19.2,
--       J-79·J-94), 신청서 관리에서 연락 여부·진행 단계를 한 행으로 보려 한다(기획 §19.1, J-82~J-85).
--       정본: develop §15.1 · §15.5.
-- 범위:
--   ① application_performances(신규) — 신청 ↔ 관심(희망) 작품. 신청·작품이 지워지면 CASCADE(보유기간 파기 FN-20 이
--      신청을 지우면 같이 지워진다 — 서버 코드 변경 없음). PK(application_id, performance_id) + performance_id 인덱스.
--   ② applications(기존) 컬럼: interest_undecided(아직 모르겠어요 — 옛 행 NULL) · contacted_at · contact_note(≤200) ·
--      progress(RECEIVED|SCHEDULED|COMPLETED|JOINED|DROPPED, 기본 RECEIVED) · progress_updated_at.
--      CHECK: JOINED 는 상담만, 거절(REJECTED)이면 DROPPED. 인덱스 (progress) · (contacted_at).
--   ③ 기존 행 채우기(컬럼을 처음 만들 때 한 번만): 거절 → DROPPED, 단원 등록된 상담 → JOINED, 나머지 RECEIVED, 모두 연락 전.
--      변경 규칙 트리거 applications_guard_update 는 신청 내용 컬럼·status·processed_at 만 비교하므로 새 컬럼 갱신을 막지 않는다.
--   ④ 새 테이블 RLS + sam_app_all 정책 + GRANT(SELECT·INSERT·DELETE — 관심 작품은 접수 때만 쓰고 고치지 않는다),
--      anon·authenticated·PUBLIC 회수, 끝 검사(V1_0_2 와 같은 식).
-- 안전성: 운영에는 실데이터 신청이 있다.
--   - 기존 테이블 변경은 컬럼 추가(NULL 또는 기본값)·CHECK 추가뿐. 채우기는 CHECK 를 만들기 전에 해서 기존 행이 모두 만족한다.
--   - 다른 미배포 트랙(V1_0_6 일정 취소 등)의 객체를 참조하지 않는다(J-96). 다시 실행해도 같은 결과(존재 확인).
-- ----------------------------------------------------------------------

-- ── ① application_performances ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS application_performances (
    application_id UUID        NOT NULL REFERENCES applications (id) ON DELETE CASCADE,
    performance_id UUID        NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_application_performances PRIMARY KEY (application_id, performance_id)
);
-- 관리 목록 작품 필터(AP-6) · performance_id FK 인덱스(application_id 는 PK 앞 열이 겸한다)
CREATE INDEX IF NOT EXISTS idx_application_performances_performance_id ON application_performances (performance_id);

-- ── ② · ③ applications 컬럼 + 기존 행 채우기 ─────────────────────────────
ALTER TABLE applications ADD COLUMN IF NOT EXISTS interest_undecided  BOOLEAN      NULL;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS contacted_at        TIMESTAMPTZ  NULL;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS contact_note        VARCHAR(200) NULL;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS progress_updated_at TIMESTAMPTZ  NULL;

DO $$
BEGIN
    -- progress 는 처음 만들 때만 채운다(다시 실행해도 관리자가 바꾼 값을 덮지 않게)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'applications' AND column_name = 'progress'
    ) THEN
        ALTER TABLE applications ADD COLUMN progress VARCHAR(20) NOT NULL DEFAULT 'RECEIVED';
        UPDATE applications SET progress = 'DROPPED' WHERE status = 'REJECTED';
        UPDATE applications SET progress = 'JOINED'
         WHERE app_type = 'CONSULTATION' AND member_id IS NOT NULL AND status <> 'REJECTED';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.applications'::regclass AND conname = 'ck_applications_progress') THEN
        ALTER TABLE applications ADD CONSTRAINT ck_applications_progress
            CHECK (progress IN ('RECEIVED', 'SCHEDULED', 'COMPLETED', 'JOINED', 'DROPPED'));
    END IF;
    -- 입단(JOINED)은 상담만(APP_012)
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.applications'::regclass AND conname = 'ck_applications_progress_joined') THEN
        ALTER TABLE applications ADD CONSTRAINT ck_applications_progress_joined
            CHECK (progress <> 'JOINED' OR app_type = 'CONSULTATION');
    END IF;
    -- 거절된 신청은 DROPPED 고정(J-82)
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.applications'::regclass AND conname = 'ck_applications_progress_rejected') THEN
        ALTER TABLE applications ADD CONSTRAINT ck_applications_progress_rejected
            CHECK (status <> 'REJECTED' OR progress = 'DROPPED');
    END IF;
END
$$;

-- 관리 목록 필터·정렬(AP-12) · 요약 연락 전 건수(AP-13)
CREATE INDEX IF NOT EXISTS idx_applications_progress ON applications (progress);
CREATE INDEX IF NOT EXISTS idx_applications_contacted_at ON applications (contacted_at);

-- ── ④ 권한 · RLS ─────────────────────────────────────────────────────
GRANT SELECT, INSERT, DELETE ON application_performances TO sam_app;

DO $$
DECLARE
    r text;
BEGIN
    ALTER TABLE public.application_performances ENABLE ROW LEVEL SECURITY;
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname = 'public' AND tablename = 'application_performances' AND policyname = 'sam_app_all'
    ) THEN
        CREATE POLICY sam_app_all ON public.application_performances
            AS PERMISSIVE FOR ALL TO sam_app USING (true) WITH CHECK (true);
    END IF;
    REVOKE ALL ON public.application_performances FROM PUBLIC;
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF to_regrole(r) IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON public.application_performances FROM %I', r);
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
        RAISE EXCEPTION 'V1_0_7 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
