-- ----------------------------------------------------------------------
-- V1_0_10(임시 번호 — 배포 때 release-manager 가 빈 번호로 바꾼다, 기획 §22.3): 좌석 지정 예매(U35) + 초대자 드롭다운(U36)
-- 배경: 극장 좌석 배치를 받아 관객이 좌석을 골라 예매하고, 이미 잡힌 좌석은 다시 고를 수 없게 한다(사용자 U35, 2026-11-20).
--       예매 폼의 '초대한 단원'을 배우 드롭다운 + "임원·스태프 및 관계자" 고정 선택지로 바꾼다(사용자 U36, 2026-11-20).
--       정본: 기획 develop §19(계약 확정본) · project-manager.md §24. U36 은 지휘자 기본안(정본 기록 전).
-- 범위:
--   ① performances.seat_selection_enabled — 공연 단위 좌석 지정 스위치(기본 꺼짐 — 꺼지면 지금처럼 매수만).
--   ② show_seat_layouts(회차당 1행) — 격자 크기(행 1~40 × 칸 1~60). 무대는 위쪽 고정(화면 규칙 — 컬럼 없음).
--   ③ show_seats — 격자 칸(SEAT·AISLE·VOID). 좌석(SEAT)만 열 이름·번호가 있고 회차 안에서 (열, 번호) 유일.
--      런타임 계정은 UPDATE 권한이 없다(배치 저장 = 바뀐 칸만 삭제 + 다시 추가 — 예매 좌석 id 를 바꾸는 경로를 두지 않는다).
--   ④ reservation_seats — 예매 ↔ 좌석. **부분 유니크 (show_id, seat_id) WHERE active** 가 중복 예매를 막는다(J-103 홀드 없음).
--      active 는 예매 상태를 따라간다: 예매가 CANCELLED 가 되면 같은 트랜잭션에서 false, 되살리면 true(트리거 —
--      공개·관리·일괄 취소·일일 작업 어느 경로로 바뀌어도 같은 문장 안에서 맞춰진다). 되살릴 때 다른 예매가 그 좌석을 잡았으면
--      유니크 위반으로 롤백(서버는 그 전에 좌석 잠금 안에서 확인해 409 SEAT_001 로 알린다).
--      쓰기 규칙 트리거: 좌석·예매가 같은 회차, 좌석은 SEAT 칸, active 는 예매가 살아 있을 때만 true, 키 열은 바꾸지 않는다.
--   ⑤ U36: members.inviter_listed(예매 초대자 목록 표시 — 기본 true, 관리자가 끌 수 있음),
--      reservations.inviter_category(MEMBER | STAFF_RELATED — 기존 행은 NULL 그대로 호환, STAFF_RELATED 면 단원 없음).
--   ⑥ 새 테이블 3개 RLS + sam_app_all 정책 + GRANT, anon·authenticated·PUBLIC 회수, 끝 검사(V1_0_4 와 같은 식).
-- 안전성: 운영에는 V1~V1_0_4 와 실데이터가 있다.
--   - 기존 테이블 변경은 기본값 있는 컬럼 추가와 CHECK 추가뿐 — 기존 행을 지우거나 바꾸지 않는다(새 CHECK 는 NULL·기본값으로 통과).
--   - 다른 미배포 트랙(T-SA·T-PR·T-R2·T-R3)의 테이블·컬럼을 참조하지 않는다(develop J-96).
--   - 모든 객체는 IF NOT EXISTS / CREATE OR REPLACE / DO 블록 존재 확인으로 만든다(다시 실행해도 같은 결과).
--   - 마이그레이션 안에서 flyway_schema_history 는 건드리지 않는다.
-- ----------------------------------------------------------------------

-- ── ① performances.seat_selection_enabled ─────────────────────────────
ALTER TABLE performances ADD COLUMN IF NOT EXISTS seat_selection_enabled BOOLEAN NOT NULL DEFAULT false;

-- ── ② show_seat_layouts: 회차 좌석 배치 크기 ───────────────────────────
CREATE TABLE IF NOT EXISTS show_seat_layouts (
    show_id    UUID        NOT NULL PRIMARY KEY REFERENCES shows (id) ON DELETE CASCADE,
    row_count  SMALLINT    NOT NULL,
    col_count  SMALLINT    NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_show_seat_layouts_row_count CHECK (row_count BETWEEN 1 AND 40),
    CONSTRAINT ck_show_seat_layouts_col_count CHECK (col_count BETWEEN 1 AND 60)
);
CREATE OR REPLACE TRIGGER trg_show_seat_layouts_updated_at
    BEFORE UPDATE ON show_seat_layouts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── ③ show_seats: 격자 칸 ─────────────────────────────────────────────
-- 위치는 0부터(row_index 0 = 무대에 가장 가까운 행). 배치 크기 안인지는 서버가 확인한다(행 단위 CHECK 로는 다른 표를 못 본다).
CREATE TABLE IF NOT EXISTS show_seats (
    id          UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    show_id     UUID        NOT NULL REFERENCES shows (id) ON DELETE CASCADE,
    row_index   SMALLINT    NOT NULL,
    col_index   SMALLINT    NOT NULL,
    kind        VARCHAR(10) NOT NULL,
    row_label   VARCHAR(5)  NULL,
    seat_number SMALLINT    NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_show_seats_position UNIQUE (show_id, row_index, col_index),
    CONSTRAINT ck_show_seats_row_index CHECK (row_index BETWEEN 0 AND 39),
    CONSTRAINT ck_show_seats_col_index CHECK (col_index BETWEEN 0 AND 59),
    CONSTRAINT ck_show_seats_kind CHECK (kind IN ('SEAT', 'AISLE', 'VOID')),
    -- 좌석만 열 이름·번호가 있다(통로·사용 안 함은 둘 다 NULL)
    CONSTRAINT ck_show_seats_seat_fields CHECK (
        (kind = 'SEAT' AND row_label IS NOT NULL AND seat_number IS NOT NULL)
        OR (kind <> 'SEAT' AND row_label IS NULL AND seat_number IS NULL)
    ),
    CONSTRAINT ck_show_seats_row_label CHECK (row_label IS NULL OR char_length(btrim(row_label)) BETWEEN 1 AND 5),
    CONSTRAINT ck_show_seats_seat_number CHECK (seat_number IS NULL OR seat_number BETWEEN 1 AND 999)
);
-- 회차 안에서 좌석 이름(열·번호)이 겹치지 않게 — 좌석 칸만
CREATE UNIQUE INDEX IF NOT EXISTS uq_show_seats_label_number
    ON show_seats (show_id, row_label, seat_number) WHERE kind = 'SEAT';
-- show_id FK 는 uq_show_seats_position(show_id, …) 이 앞 열로 겸한다

-- ── ④ reservation_seats: 예매 좌석 ───────────────────────────────────
CREATE TABLE IF NOT EXISTS reservation_seats (
    reservation_id UUID        NOT NULL REFERENCES reservations (id) ON DELETE CASCADE,
    show_id        UUID        NOT NULL REFERENCES shows (id) ON DELETE CASCADE,
    seat_id        UUID        NOT NULL REFERENCES show_seats (id) ON DELETE RESTRICT,
    active         BOOLEAN     NOT NULL DEFAULT true,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_reservation_seats PRIMARY KEY (reservation_id, seat_id)
);
-- 중복 예매 방지 — 살아 있는(입금 대기·확정) 예매의 좌석만 회차 안에서 유일
CREATE UNIQUE INDEX IF NOT EXISTS uq_reservation_seats_active
    ON reservation_seats (show_id, seat_id) WHERE active;
-- 좌석 FK(배치 저장 때 RESTRICT 확인 · 좌석별 예매 찾기)
CREATE INDEX IF NOT EXISTS idx_reservation_seats_seat_id ON reservation_seats (seat_id);
-- 회차 FK(회차 삭제 CASCADE · 취소 포함 회차 좌석 조회)
CREATE INDEX IF NOT EXISTS idx_reservation_seats_show_id ON reservation_seats (show_id);

-- 쓰기 규칙: 좌석과 예매가 같은 회차 · 좌석 칸(SEAT)만 · active 는 예매가 살아 있을 때만 true · 키 열 불변
CREATE OR REPLACE FUNCTION reservation_seats_guard_write() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    reservation_status text;
BEGIN
    IF TG_OP = 'UPDATE' AND (NEW.reservation_id, NEW.show_id, NEW.seat_id, NEW.created_at)
       IS DISTINCT FROM (OLD.reservation_id, OLD.show_id, OLD.seat_id, OLD.created_at) THEN
        RAISE EXCEPTION '예매 좌석의 예매·회차·좌석은 바꿀 수 없다(reservation_seats %)', OLD.reservation_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM show_seats s WHERE s.id = NEW.seat_id AND s.show_id = NEW.show_id AND s.kind = 'SEAT') THEN
            RAISE EXCEPTION '그 회차의 좌석 칸이 아니다(reservation_seats seat %, show %)', NEW.seat_id, NEW.show_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    SELECT r.status INTO reservation_status FROM reservations r WHERE r.id = NEW.reservation_id AND r.show_id = NEW.show_id;
    IF reservation_status IS NULL THEN
        RAISE EXCEPTION '예매와 회차가 맞지 않는다(reservation_seats reservation %, show %)', NEW.reservation_id, NEW.show_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.active AND reservation_status = 'CANCELLED' THEN
        RAISE EXCEPTION '취소된 예매의 좌석은 잡을 수 없다(reservation_seats %)', NEW.reservation_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER trg_reservation_seats_guard_write
    BEFORE INSERT OR UPDATE ON reservation_seats FOR EACH ROW EXECUTE FUNCTION reservation_seats_guard_write();

-- 예매 상태 ↔ 좌석 active 동기화(같은 트랜잭션 — 취소면 풀고, 되살리면 다시 잡는다. 이미 잡혔으면 유니크 위반으로 롤백)
CREATE OR REPLACE FUNCTION reservations_sync_seat_active() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED' THEN
        UPDATE reservation_seats SET active = false WHERE reservation_id = NEW.id AND active;
    ELSIF OLD.status = 'CANCELLED' AND NEW.status <> 'CANCELLED' THEN
        UPDATE reservation_seats SET active = true WHERE reservation_id = NEW.id AND NOT active;
    END IF;
    RETURN NULL;
END
$$;
CREATE OR REPLACE TRIGGER trg_reservations_sync_seat_active
    AFTER UPDATE OF status ON reservations FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION reservations_sync_seat_active();

-- ── ⑤ U36: 초대자 드롭다운 ───────────────────────────────────────────
-- 예매 초대자 목록 표시(배우 단원 대상 — 공개 여부 is_visible 과 무관, 사용자 결정 2026-11-20 "비공개와 상관없이"). 기본 true
ALTER TABLE members ADD COLUMN IF NOT EXISTS inviter_listed BOOLEAN NOT NULL DEFAULT true;
-- 초대 구분 — MEMBER(단원 초대) · STAFF_RELATED(임원·스태프 및 관계자 — 단원 없음). 기존 예매는 NULL(단원/직접 입력/없음으로 판단)
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS inviter_category VARCHAR(20) NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reservations'::regclass AND conname = 'ck_reservations_inviter_category') THEN
        ALTER TABLE reservations ADD CONSTRAINT ck_reservations_inviter_category
            CHECK (inviter_category IS NULL OR inviter_category IN ('MEMBER', 'STAFF_RELATED'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.reservations'::regclass AND conname = 'ck_reservations_inviter_category_member') THEN
        ALTER TABLE reservations ADD CONSTRAINT ck_reservations_inviter_category_member
            CHECK (inviter_category IS DISTINCT FROM 'STAFF_RELATED' OR inviter_member_id IS NULL);
    END IF;
END
$$;

-- ── ⑥ 권한 · RLS ─────────────────────────────────────────────────────
GRANT SELECT, INSERT, UPDATE, DELETE ON show_seat_layouts TO sam_app;
-- 칸: 교체 = 삭제 + 추가(UPDATE 없음 — 예매에 걸린 좌석의 위치·이름을 바꾸는 경로를 두지 않는다)
GRANT SELECT, INSERT, DELETE ON show_seats TO sam_app;
-- 예매 좌석: active 갱신(동기화 트리거는 호출자 권한으로 돈다) · 좌석 변경 = 삭제 + 추가
GRANT SELECT, INSERT, UPDATE, DELETE ON reservation_seats TO sam_app;

DO $$
DECLARE
    new_tables CONSTANT text[] := ARRAY['show_seat_layouts', 'show_seats', 'reservation_seats'];
    new_functions CONSTANT text[] := ARRAY['reservation_seats_guard_write()', 'reservations_sync_seat_active()'];
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

-- ── ⑦ 끝 검사 — 위반 0건이 아니면 롤백 ─────────────────────────────────
-- 아래 begin·end 표시 사이는 scripts/check-security.sql 과 같은 식이어야 한다(scripts/check-security.test.mjs 가 비교한다).
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
        RAISE EXCEPTION 'V1_0_10 끝 검사 실패 — 권한·RLS 위반 %건: %', violation_count, violation_list;
    END IF;
END
$$;
