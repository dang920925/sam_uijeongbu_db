-- ----------------------------------------------------------------------
-- V1_0_9(임시 번호 — 배포 때 release-manager 가 빈 번호로 바꾼다, 기획 §22.3): 공연 팀 계정 + 연습실 예약 (U34, 트랙 T-PR)
-- 배경: 공연에 참가한 배우들이 홈페이지에서 팀 계정으로 로그인해 연습실 시간을 예약한다(사용자 결정 U34, 2026-11-20).
--       작품마다 팀 계정(처음 1개 자동 — Dear-A, 팀이 나뉘면 Dear-B …)을 두고, 공연이 끝나면 일일 작업이 모두 폐기한다.
--       정본: 기획 develop §18.1(계약 확정본) · J-98(연습실 1개 — room 컬럼 없음) · J-99(해시 + 암호화 사본) · J-100(30분 단위·
--       30분~4시간·8주) · J-101(지난 예약 90일 뒤 파기) · J-102(접두어 기본값).
-- 범위:
--   ① performances(기존): team_prefix VARCHAR(20) NULL — 팀 아이디 접두어(영문·숫자 1~20자). NULL = 아직 팀 계정을 만들지 않은 작품.
--   ② team_accounts(신규): 작품별 팀 계정. 아이디 `{접두어}-{라벨}` 은 대소문자 무시 전역 유일(lower(username) 유니크 인덱스).
--      비밀번호는 argon2id PHC(로그인 검증) + AES-256-GCM 암호화 사본 `iv.ciphertext.tag`(base64 — 대시보드 다시 보기·복사, J-99).
--      평문은 저장하지 않는다(CHECK 로 해시 형식 강제). 잠금(연속 실패·잠금 시각)·세션 버전은 관리자 계정(admins)과 같은 방식.
--   ③ room_reservations(신규): 연습실 예약. **겹침은 DB 가 막는다** — EXCLUDE USING gist(tstzrange [) &&) WHERE deleted_at IS NULL.
--      서버의 사전 검사가 동시 요청에 뚫려도 두 번째 INSERT·UPDATE 는 23P01 로 실패한다(→ 409 ROOM_001, 수용 기준 PR-3).
--      30분 단위·30분~4시간도 CHECK 로 이중 방어(오늘~8주·지난 시각 금지는 "지금"에 따라 바뀌어 서버가 맡는다).
--      팀 계정이 지워져도(작품 하드 삭제 외에는 없음) 예약 기록은 남게 team_account_id 는 SET NULL, 표시용 team_name 스냅숏.
--   ④ 두 새 테이블 RLS + sam_app_all 정책 + GRANT(sam_app: SELECT·INSERT·UPDATE·DELETE), anon·authenticated·PUBLIC 회수, 끝 검사.
--   tstzrange 의 && 는 내장 range_ops(gist)로 충분하다 — btree_gist 확장이 필요 없다(같은 컬럼 등호 조건을 섞지 않으므로).
-- 안전성: 운영(Supabase)에 V1~V1_0_4 와 실데이터가 있다.
--   - 기존 테이블 변경은 performances 에 NULL 컬럼 1개 + CHECK 추가뿐 — 기존 행을 바꾸지 않는다(기존 작품은 대시보드 탭에서
--     "팀 계정 만들기"로 접두어·A 계정을 만든다).
--   - 다른 미배포 트랙(T-SA·T-SEAT·T-PUSH 등)의 테이블·컬럼을 참조하지 않는다(develop J-96).
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 새 함수는 만들지 않는다(updated_at 은 V1 의 set_updated_at 재사용).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다(V1_0_2 교착 교훈).
-- ----------------------------------------------------------------------

-- ── ① performances.team_prefix ──────────────────────────────────────────
ALTER TABLE performances ADD COLUMN IF NOT EXISTS team_prefix VARCHAR(20) NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conrelid = 'public.performances'::regclass AND conname = 'ck_performances_team_prefix'
    ) THEN
        ALTER TABLE performances ADD CONSTRAINT ck_performances_team_prefix
            CHECK (team_prefix IS NULL OR team_prefix ~ '^[A-Za-z0-9]{1,20}$');
    END IF;
END
$$;

-- ── ② team_accounts: 작품별 팀 계정 ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS team_accounts (
    id                   UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id       UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    -- 팀 라벨 A, B, C … (Z 다음은 AA — 서버가 다음 라벨을 계산)
    label                VARCHAR(5)   NOT NULL,
    -- `{접두어}-{라벨}`(예 Dear-A) — 표시는 저장한 대소문자 그대로, 비교는 lower()
    username             VARCHAR(30)  NOT NULL,
    -- argon2id PHC 문자열(로그인 검증)
    password_hash        VARCHAR(255) NOT NULL,
    -- AES-256-GCM 암호화 사본 `iv.ciphertext.tag`(각 base64) — 키는 서버 env TEAM_PASSWORD_KEY(J-99)
    password_enc         TEXT         NOT NULL,
    -- 토큰 클레임 sv 와 같을 때만 세션 유효(재발급·비활성·접두어 변경·폐기 시 +1 — PR-6)
    session_version      INTEGER      NOT NULL DEFAULT 1,
    consecutive_failures INTEGER      NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ  NULL,
    is_active            BOOLEAN      NOT NULL DEFAULT true,
    -- 일일 작업이 공연 종료로 폐기한 시각(관리자가 다시 켜면 지운다)
    revoked_at           TIMESTAMPTZ  NULL,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_team_accounts_performance_label UNIQUE (performance_id, label),
    CONSTRAINT ck_team_accounts_label CHECK (label ~ '^[A-Z]{1,5}$'),
    CONSTRAINT ck_team_accounts_username CHECK (username ~ '^[A-Za-z0-9-]{3,30}$'),
    CONSTRAINT ck_team_accounts_password_hash CHECK (password_hash LIKE '$argon2id$%'),
    CONSTRAINT ck_team_accounts_password_enc
        CHECK (password_enc ~ '^[A-Za-z0-9+/]+={0,2}\.[A-Za-z0-9+/]+={0,2}\.[A-Za-z0-9+/]+={0,2}$'),
    CONSTRAINT ck_team_accounts_session_version CHECK (session_version >= 1),
    CONSTRAINT ck_team_accounts_consecutive_failures CHECK (consecutive_failures >= 0),
    -- 폐기된 계정은 사용 중일 수 없다
    CONSTRAINT ck_team_accounts_revoked_inactive CHECK (revoked_at IS NULL OR is_active = false)
);
-- 아이디 전역 유일(대소문자 무시 — Dear-A 와 dear-a 는 같은 아이디). 로그인 조회도 이 인덱스를 탄다
CREATE UNIQUE INDEX IF NOT EXISTS uq_team_accounts_username_lower ON team_accounts (lower(username));
-- performance_id FK 인덱스는 uq_team_accounts_performance_label(performance_id, label)이 겸한다
CREATE OR REPLACE TRIGGER trg_team_accounts_updated_at
    BEFORE UPDATE ON team_accounts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ③ room_reservations: 연습실 예약(연습실 1개 — J-98) ───────────────────
CREATE TABLE IF NOT EXISTS room_reservations (
    id              UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    team_account_id UUID         NULL REFERENCES team_accounts (id) ON DELETE SET NULL,
    performance_id  UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    -- 예약한 팀 아이디 스냅숏(다른 팀에게 보이는 유일한 정보 — 접두어가 바뀌어도 기록은 그때 이름)
    team_name       VARCHAR(30)  NOT NULL,
    start_at        TIMESTAMPTZ  NOT NULL,
    end_at          TIMESTAMPTZ  NOT NULL,
    -- 내 팀에게만 보이는 메모(개인정보 금지 안내 — 화면)
    memo            VARCHAR(200) NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ  NULL,
    CONSTRAINT ck_room_reservations_time_order CHECK (end_at > start_at),
    -- 30분 단위(KST 오프셋 +9h 도 30분의 배수라 UTC 기준 검사와 같다) — 고정 기준시각과의 간격(interval)은 IMMUTABLE 식
    CONSTRAINT ck_room_reservations_half_hour CHECK (
        mod(EXTRACT(EPOCH FROM (start_at - TIMESTAMPTZ '2000-01-01 00:00:00+00'))::numeric, 1800) = 0
        AND mod(EXTRACT(EPOCH FROM (end_at - TIMESTAMPTZ '2000-01-01 00:00:00+00'))::numeric, 1800) = 0
    ),
    -- 한 번에 30분~4시간(J-100)
    CONSTRAINT ck_room_reservations_duration
        CHECK (end_at - start_at BETWEEN INTERVAL '30 minutes' AND INTERVAL '4 hours'),
    CONSTRAINT ck_room_reservations_team_name CHECK (team_name ~ '^[A-Za-z0-9-]{3,30}$'),
    CONSTRAINT ck_room_reservations_memo_not_blank CHECK (memo IS NULL OR char_length(btrim(memo)) > 0)
);

DO $$
BEGIN
    -- 겹침 금지(J-98·J-100, PR-3) — 삭제되지 않은 예약끼리 [start, end) 구간이 겹치면 23P01.
    -- 끝 = 다음 시작은 겹침이 아니다('[)' 반열린 구간).
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'public.room_reservations'::regclass AND conname = 'ex_room_reservations_no_overlap'
    ) THEN
        ALTER TABLE room_reservations ADD CONSTRAINT ex_room_reservations_no_overlap
            EXCLUDE USING gist (tstzrange(start_at, end_at, '[)') WITH &&) WHERE (deleted_at IS NULL);
    END IF;
END
$$;
-- 기간 조회(캘린더 주·월) — 시작 시각 순
CREATE INDEX IF NOT EXISTS idx_room_reservations_start_at ON room_reservations (start_at);
-- FK 인덱스
CREATE INDEX IF NOT EXISTS idx_room_reservations_team_account_id ON room_reservations (team_account_id);
CREATE INDEX IF NOT EXISTS idx_room_reservations_performance_id ON room_reservations (performance_id);
CREATE OR REPLACE TRIGGER trg_room_reservations_updated_at
    BEFORE UPDATE ON room_reservations FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ④ 권한 · RLS ─────────────────────────────────────────────────────
-- 팀 계정: 관리(생성·재발급·비활성) + 로그인(잠금·세션) + 작품 하드 삭제 CASCADE 대비 DELETE
-- 연습실 예약: 팀·관리자 쓰기(소프트 삭제) + 일일 작업 파기(영구 삭제)
GRANT SELECT, INSERT, UPDATE, DELETE ON team_accounts, room_reservations TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['team_accounts', 'room_reservations'];
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
        RAISE EXCEPTION 'V1_0_9 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
