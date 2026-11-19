-- ----------------------------------------------------------------------
-- V1: SAM 의정부 초기 스키마 (재작성 — 2026-11-19)
-- 배경: 기존 V1(e4cda98)은 실제 운영 스키마(server prisma/schema.prisma @f1dca34)와 달랐다
--       (classes.day_of_week vs days_of_week, applications 상담 컬럼·staff 없음 등).
--       새 Supabase 프로젝트에는 운영 데이터가 없으므로 실제 스키마 기준으로 V1 을 다시 쓴다
--       (기획 develop §4 · 자체 결정 J-06).
-- 범위: 테이블 14개(admins · performances · performance_detail_images · classes · class_days · shows ·
--       members · actor_profiles · actor_filmographies · applications · galleries · schedules · staff · popups),
--       updated_at 트리거, 신청서 변경 규칙 트리거.
--       - PG enum 9종 → VARCHAR + CHECK(UPPER_SNAKE 코드값, 가이드 B2). DB enum 타입은 쓰지 않는다.
--       - 다중값(Json) → 조인 테이블: detail_images · days_of_week · filmography.
--       - 시각은 TIMESTAMPTZ(UTC 저장, 표시·계산은 Asia/Seoul), 날짜만이면 DATE, 벽시계 시각은 TIME(KST).
--       - id 는 UUID. 새 행의 id 는 서버가 UUID v7 로 만든다. DB 기본값 gen_random_uuid() 는 안전망.
--       - URL 컬럼은 스킴을 CHECK 로 제한한다(javascript: 등 차단, 가이드 A17.2).
--         · 외부 링크(sns_url · link_url): https 만.
--         · 이미지 URL(포스터·상세·프로필·갤러리·팝업): https 또는 루프백 http(localhost·127.0.0.1) —
--           로컬·E2E 의 대체 저장소(서버 STORAGE_DRIVER=local)가 http://localhost 공개 주소를 쓰기 때문이다.
--           운영에서는 서버가 Supabase 공개 URL 접두사(https)만 받는다(UPL_003, SUPABASE_URL https 부팅 검증).
--       - 제외: bookings·static_contents(사용처 없음 / FN-26 제외), schedules.is_recurring·recur_rule·show_id,
--         actor_profiles.extra_images, classes.actors, admins.role (자체 결정 J-08).
-- 안전성: 모든 객체를 IF NOT EXISTS / CREATE OR REPLACE 로 만들어 다시 실행해도 같은 결과다(멱등).
--         시드 없음(실데이터 없음 — develop §4 "개발용 목업 시드는 두지 않는다").
--         권한·RLS 는 V1_0_1(런타임 역할)·V1_0_2(RLS·anon 회수)에서 다룬다.
-- ----------------------------------------------------------------------

-- ── 공용 트리거 함수: updated_at 자동 갱신 ─────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

-- ── admins: 관리자 계정 (FN-08 · FN-21) ───────────────────────────────
-- 계정 1종(role 컬럼 제거). 잠금(consecutive_failures·locked_until·hard_locked_at)과
-- 로그아웃 무효화(session_version)를 DB 에 둔다 — 서버리스 인스턴스가 여러 개여도 같은 상태(가이드 A17 계정 잠금).
CREATE TABLE IF NOT EXISTS admins (
    id                   UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    username             VARCHAR(50)  NOT NULL,
    password_hash        VARCHAR(255) NOT NULL,
    consecutive_failures INTEGER      NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ  NULL,
    hard_locked_at       TIMESTAMPTZ  NULL,
    session_version      INTEGER      NOT NULL DEFAULT 1,
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_admins_username UNIQUE (username),
    CONSTRAINT ck_admins_username_not_blank CHECK (char_length(btrim(username)) > 0),
    -- argon2id PHC 문자열만(평문·bcrypt 잔재 저장 방지)
    CONSTRAINT ck_admins_password_hash_argon2id CHECK (password_hash LIKE '$argon2id$%'),
    CONSTRAINT ck_admins_consecutive_failures CHECK (consecutive_failures >= 0),
    CONSTRAINT ck_admins_session_version CHECK (session_version >= 1)
);
CREATE OR REPLACE TRIGGER trg_admins_updated_at
    BEFORE UPDATE ON admins FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── performances: 공연(작품) (FN-01 · FN-09) ───────────────────────────
CREATE TABLE IF NOT EXISTS performances (
    id               UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    title            VARCHAR(100) NOT NULL,
    type             VARCHAR(20)  NOT NULL,
    status           VARCHAR(20)  NOT NULL,
    description      TEXT         NULL,
    poster_image_url VARCHAR(500) NULL,
    is_visible       BOOLEAN      NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at       TIMESTAMPTZ  NULL,
    CONSTRAINT ck_performances_type CHECK (type IN ('MUSICAL', 'PLAY', 'SEMINAR', 'ETC')),
    CONSTRAINT ck_performances_status CHECK (status IN ('UPCOMING', 'ONGOING', 'ENDED')),
    CONSTRAINT ck_performances_title_not_blank CHECK (char_length(btrim(title)) > 0),
    CONSTRAINT ck_performances_description_length CHECK (description IS NULL OR char_length(description) <= 5000),
    CONSTRAINT ck_performances_poster_url CHECK (poster_image_url IS NULL OR poster_image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)')
);
-- 공개·관리 목록: 삭제 안 된 행을 created_at desc 로(B10)
CREATE INDEX IF NOT EXISTS idx_performances_created_at
    ON performances (created_at DESC) WHERE deleted_at IS NULL;
CREATE OR REPLACE TRIGGER trg_performances_updated_at
    BEFORE UPDATE ON performances FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── performance_detail_images: 공연 상세 이미지(순서 있음) — 기존 detail_images Json 대체 ──
CREATE TABLE IF NOT EXISTS performance_detail_images (
    id             UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    image_url      VARCHAR(500) NOT NULL,
    sort_order     SMALLINT     NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- (performance_id, sort_order) 유니크 인덱스가 FK 인덱스를 겸한다
    CONSTRAINT uq_performance_detail_images_order UNIQUE (performance_id, sort_order),
    CONSTRAINT ck_performance_detail_images_sort_order CHECK (sort_order BETWEEN 0 AND 19),
    CONSTRAINT ck_performance_detail_images_url CHECK (image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)')
);

-- ── classes: 운영반 (FN-06 · FN-10) ───────────────────────────────────
-- start_time·end_time 은 KST 벽시계 시각(TIME). 요일은 class_days 조인 테이블(B6).
CREATE TABLE IF NOT EXISTS classes (
    id             UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    performance_id UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    name           VARCHAR(100) NOT NULL,
    start_time     TIME         NULL,
    end_time       TIME         NULL,
    deadline       DATE         NULL,
    location       VARCHAR(200) NULL,
    status         VARCHAR(20)  NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_classes_status CHECK (status IN ('ACTIVE', 'INACTIVE')),
    CONSTRAINT ck_classes_name_not_blank CHECK (char_length(btrim(name)) > 0),
    CONSTRAINT ck_classes_time_order CHECK (start_time IS NULL OR end_time IS NULL OR end_time > start_time)
);
CREATE INDEX IF NOT EXISTS idx_classes_performance_id ON classes (performance_id);
CREATE OR REPLACE TRIGGER trg_classes_updated_at
    BEFORE UPDATE ON classes FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── class_days: 반 요일(다중값) — 0=일 … 6=토 (JS getDay 와 같은 번호) ──
CREATE TABLE IF NOT EXISTS class_days (
    class_id    UUID     NOT NULL REFERENCES classes (id) ON DELETE CASCADE,
    day_of_week SMALLINT NOT NULL,
    -- PK(class_id, day_of_week) 가 FK 인덱스를 겸한다
    CONSTRAINT pk_class_days PRIMARY KEY (class_id, day_of_week),
    CONSTRAINT ck_class_days_day_of_week CHECK (day_of_week BETWEEN 0 AND 6)
);

-- ── shows: 공연 회차 (FN-01 읽기만 — 관리 UI 는 FN-28 로 범위 제외) ──
CREATE TABLE IF NOT EXISTS shows (
    id              UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    class_id        UUID         NOT NULL REFERENCES classes (id) ON DELETE CASCADE,
    performance_id  UUID         NOT NULL REFERENCES performances (id) ON DELETE CASCADE,
    show_date       DATE         NOT NULL,
    start_time      TIME         NOT NULL,
    end_time        TIME         NULL,
    venue           VARCHAR(200) NULL,
    status          VARCHAR(20)  NOT NULL,
    booking_open_at TIMESTAMPTZ  NULL,
    total_seats     INTEGER      NULL,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_shows_status CHECK (status IN ('UPCOMING', 'BOOKING_OPEN', 'COMPLETED')),
    CONSTRAINT ck_shows_total_seats CHECK (total_seats IS NULL OR total_seats >= 0)
);
CREATE INDEX IF NOT EXISTS idx_shows_class_id ON shows (class_id);
CREATE INDEX IF NOT EXISTS idx_shows_performance_id ON shows (performance_id, show_date);

-- ── members: 단원 (FN-11 · FN-13) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS members (
    id         UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name       VARCHAR(50) NOT NULL,
    type       VARCHAR(20) NOT NULL,
    phone      VARCHAR(20) NULL,
    is_visible BOOLEAN     NOT NULL DEFAULT false,
    joined_at  DATE        NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ NULL,
    CONSTRAINT ck_members_type CHECK (type IN ('GENERAL', 'ACTOR')),
    CONSTRAINT ck_members_name_not_blank CHECK (char_length(btrim(name)) > 0)
);
CREATE INDEX IF NOT EXISTS idx_members_created_at
    ON members (created_at DESC) WHERE deleted_at IS NULL;
CREATE OR REPLACE TRIGGER trg_members_updated_at
    BEFORE UPDATE ON members FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── actor_profiles: 배우 프로필 (FN-02 · FN-12) — 단원 1명당 0~1개 ──
CREATE TABLE IF NOT EXISTS actor_profiles (
    id                UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    member_id         UUID         NOT NULL REFERENCES members (id) ON DELETE CASCADE,
    profile_image_url VARCHAR(500) NULL,
    intro             VARCHAR(200) NULL,
    sns_url           VARCHAR(500) NULL,
    activity_start    DATE         NULL,
    display_order     INTEGER      NOT NULL DEFAULT 0,
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- 유니크 인덱스가 FK 인덱스를 겸한다
    CONSTRAINT uq_actor_profiles_member_id UNIQUE (member_id),
    CONSTRAINT ck_actor_profiles_display_order CHECK (display_order BETWEEN 0 AND 9999),
    CONSTRAINT ck_actor_profiles_profile_image_url CHECK (profile_image_url IS NULL OR profile_image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)'),
    CONSTRAINT ck_actor_profiles_sns_https CHECK (sns_url IS NULL OR sns_url ~ '^https://')
);
CREATE OR REPLACE TRIGGER trg_actor_profiles_updated_at
    BEFORE UPDATE ON actor_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── actor_filmographies: 배우 출연작(다중값) — 기존 filmography Json 대체 ──
CREATE TABLE IF NOT EXISTS actor_filmographies (
    id               UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    actor_profile_id UUID         NOT NULL REFERENCES actor_profiles (id) ON DELETE CASCADE,
    title            VARCHAR(100) NOT NULL,
    role             VARCHAR(50)  NULL,
    year             SMALLINT     NOT NULL,
    sort_order       SMALLINT     NOT NULL,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    -- (actor_profile_id, sort_order) 유니크 인덱스가 FK 인덱스를 겸한다
    CONSTRAINT uq_actor_filmographies_order UNIQUE (actor_profile_id, sort_order),
    CONSTRAINT ck_actor_filmographies_year CHECK (year BETWEEN 1900 AND 2100),
    CONSTRAINT ck_actor_filmographies_sort_order CHECK (sort_order BETWEEN 0 AND 99),
    CONSTRAINT ck_actor_filmographies_title_not_blank CHECK (char_length(btrim(title)) > 0)
);

-- ── applications: 참관·상담 신청서 (FN-07 · FN-13 · FN-20) ─────────────
-- 소프트 삭제 없음: 처리 후 보유기간(기본 90일, D7)이 지나면 일일 작업이 영구 삭제한다(개인정보 보호법 제21조).
-- member_id(D6): "단원으로 등록"으로 만든 단원. 단원이 영구 삭제되면 NULL, 신청서가 파기돼도 단원은 남는다.
CREATE TABLE IF NOT EXISTS applications (
    id                  UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    app_type            VARCHAR(30)   NOT NULL,
    performance_id      UUID          NULL REFERENCES performances (id) ON DELETE SET NULL,
    applicant_name      VARCHAR(50)   NOT NULL,
    phone               VARCHAR(20)   NOT NULL,
    preferred_date      DATE          NULL,
    preferred_time      VARCHAR(30)   NULL,
    consultation_method VARCHAR(20)   NULL,
    motivation          VARCHAR(500)  NULL,
    question            VARCHAR(1000) NULL,
    age                 SMALLINT      NULL,
    gender              VARCHAR(10)   NULL,
    status              VARCHAR(20)   NOT NULL DEFAULT 'PENDING',
    privacy_agreed_at   TIMESTAMPTZ   NOT NULL,
    processed_at        TIMESTAMPTZ   NULL,
    member_id           UUID          NULL REFERENCES members (id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT ck_applications_app_type CHECK (app_type IN ('WORK_OBSERVATION', 'CONSULTATION')),
    CONSTRAINT ck_applications_preferred_time
        CHECK (preferred_time IS NULL OR preferred_time IN ('WEEKDAY_DAY', 'WEEKDAY_EVENING', 'WEEKEND_DAY', 'WEEKEND_EVENING')),
    CONSTRAINT ck_applications_consultation_method
        CHECK (consultation_method IS NULL OR consultation_method IN ('VISIT', 'PHONE', 'ONLINE')),
    CONSTRAINT ck_applications_gender CHECK (gender IS NULL OR gender IN ('MALE', 'FEMALE', 'OTHER')),
    CONSTRAINT ck_applications_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
    CONSTRAINT ck_applications_age CHECK (age IS NULL OR age BETWEEN 0 AND 150),
    CONSTRAINT ck_applications_name_not_blank CHECK (char_length(btrim(applicant_name)) > 0),
    -- 처리 시각은 처리된 신청에만 있다
    CONSTRAINT ck_applications_processed_at
        CHECK ((status = 'PENDING' AND processed_at IS NULL) OR (status <> 'PENDING' AND processed_at IS NOT NULL)),
    -- 단원 등록은 승인된 신청에만(D6 · APP_009)
    CONSTRAINT ck_applications_member_requires_approved CHECK (member_id IS NULL OR status = 'APPROVED')
);
CREATE INDEX IF NOT EXISTS idx_applications_performance_id ON applications (performance_id);
CREATE INDEX IF NOT EXISTS idx_applications_member_id ON applications (member_id);
-- 중복 신청 검사(APP_006): 같은 전화번호·유형·상태
CREATE INDEX IF NOT EXISTS idx_applications_phone_type_status ON applications (phone, app_type, status);
-- 관리 목록(createdAt desc)·대기 건수
CREATE INDEX IF NOT EXISTS idx_applications_status_created_at ON applications (status, created_at DESC);
-- 일일 파기(FN-20): 처리 완료 + 처리 시각
CREATE INDEX IF NOT EXISTS idx_applications_processed_at
    ON applications (processed_at) WHERE status <> 'PENDING';

-- 신청서 변경 규칙(데이터 변경 정책 — data-base.md):
--   ① 신청 내용(신청자·연락처·희망 일시·동의 시각 등)은 접수 뒤 바꾸지 않는다 — 수정 API 가 없고(develop §3.4),
--      동의 기록(privacy_agreed_at)이 바뀌면 안 된다.
--   ② 상태는 PENDING → APPROVED | REJECTED 한 번만(FN-13 · APP_007). 처리된 신청은 되돌리지 않는다.
--   performance_id · member_id 는 FK ON DELETE SET NULL 이 NULL 로 바꿀 수 있어야 하므로 ①에서 뺀다
--   (member_id 를 값으로 바꾸는 것은 승인 상태 CHECK 가 막는다). 삭제(보유기간 파기)는 막지 않는다.
CREATE OR REPLACE FUNCTION applications_guard_update() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.app_type, NEW.applicant_name, NEW.phone, NEW.preferred_date, NEW.preferred_time,
        NEW.consultation_method, NEW.motivation, NEW.question, NEW.age, NEW.gender,
        NEW.privacy_agreed_at, NEW.created_at)
       IS DISTINCT FROM
       (OLD.app_type, OLD.applicant_name, OLD.phone, OLD.preferred_date, OLD.preferred_time,
        OLD.consultation_method, OLD.motivation, OLD.question, OLD.age, OLD.gender,
        OLD.privacy_agreed_at, OLD.created_at) THEN
        RAISE EXCEPTION '신청 내용은 접수 뒤 바꿀 수 없다(applications %)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.status <> 'PENDING' AND NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION '처리된 신청의 상태는 바꿀 수 없다(applications %: % → %)', OLD.id, OLD.status, NEW.status
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.processed_at IS NOT NULL AND NEW.processed_at IS DISTINCT FROM OLD.processed_at THEN
        RAISE EXCEPTION '처리 시각은 바꿀 수 없다(applications %)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;
CREATE OR REPLACE TRIGGER trg_applications_guard_update
    BEFORE UPDATE ON applications FOR EACH ROW EXECUTE FUNCTION applications_guard_update();
-- TRUNCATE 는 파기 작업(행 단위 DELETE)과 다르므로 막는다
CREATE OR REPLACE FUNCTION applications_guard_truncate() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'applications 는 TRUNCATE 할 수 없다 — 보유기간 파기는 행 단위 DELETE 로 한다'
        USING ERRCODE = 'check_violation';
END
$$;
CREATE OR REPLACE TRIGGER trg_applications_guard_truncate
    BEFORE TRUNCATE ON applications FOR EACH STATEMENT EXECUTE FUNCTION applications_guard_truncate();

-- ── galleries: 갤러리 이미지 (FN-14) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS galleries (
    id            UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    category      VARCHAR(20)  NOT NULL,
    image_url     VARCHAR(500) NOT NULL,
    description   VARCHAR(200) NULL,
    display_order INTEGER      NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ  NULL,
    CONSTRAINT ck_galleries_category CHECK (category IN ('PERFORMANCE', 'PRACTICE', 'EVENT', 'GROUP', 'ETC')),
    CONSTRAINT ck_galleries_image_url CHECK (image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)')
);
CREATE INDEX IF NOT EXISTS idx_galleries_created_at
    ON galleries (created_at DESC) WHERE deleted_at IS NULL;

-- ── schedules: 일정 (FN-03 · FN-06 · FN-15) ────────────────────────────
CREATE TABLE IF NOT EXISTS schedules (
    id             UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    title          VARCHAR(100) NOT NULL,
    type           VARCHAR(20)  NOT NULL,
    start_at       TIMESTAMPTZ  NOT NULL,
    end_at         TIMESTAMPTZ  NULL,
    location       VARCHAR(200) NULL,
    description    VARCHAR(500) NULL,
    class_id       UUID         NULL REFERENCES classes (id) ON DELETE SET NULL,
    performance_id UUID         NULL REFERENCES performances (id) ON DELETE SET NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at     TIMESTAMPTZ  NULL,
    CONSTRAINT ck_schedules_type CHECK (type IN ('PRACTICE', 'SHOW', 'EVENT', 'ETC')),
    CONSTRAINT ck_schedules_title_not_blank CHECK (char_length(btrim(title)) > 0),
    CONSTRAINT ck_schedules_time_order CHECK (end_at IS NULL OR end_at >= start_at)
);
CREATE INDEX IF NOT EXISTS idx_schedules_start_at ON schedules (start_at) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_schedules_class_id ON schedules (class_id);
CREATE INDEX IF NOT EXISTS idx_schedules_performance_id ON schedules (performance_id);
CREATE OR REPLACE TRIGGER trg_schedules_updated_at
    BEFORE UPDATE ON schedules FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── staff: 연출진 (FN-04 · FN-16) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS staff (
    id                UUID          NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    name              VARCHAR(50)   NOT NULL,
    role              VARCHAR(50)   NOT NULL,
    profile_image_url VARCHAR(500)  NULL,
    bio               VARCHAR(1000) NULL,
    display_order     INTEGER       NOT NULL DEFAULT 0,
    is_visible        BOOLEAN       NOT NULL DEFAULT true,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    deleted_at        TIMESTAMPTZ   NULL,
    CONSTRAINT ck_staff_name_not_blank CHECK (char_length(btrim(name)) > 0),
    CONSTRAINT ck_staff_role_not_blank CHECK (char_length(btrim(role)) > 0),
    CONSTRAINT ck_staff_display_order CHECK (display_order BETWEEN 0 AND 9999),
    CONSTRAINT ck_staff_profile_image_url CHECK (profile_image_url IS NULL OR profile_image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)')
);
CREATE INDEX IF NOT EXISTS idx_staff_display_order ON staff (display_order) WHERE deleted_at IS NULL;
CREATE OR REPLACE TRIGGER trg_staff_updated_at
    BEFORE UPDATE ON staff FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── popups: 홈 팝업 (FN-05 · FN-17) ───────────────────────────────────
CREATE TABLE IF NOT EXISTS popups (
    id         UUID         NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    image_url  VARCHAR(500) NOT NULL,
    link_url   VARCHAR(500) NULL,
    start_date DATE         NOT NULL,
    end_date   DATE         NOT NULL,
    is_active  BOOLEAN      NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ  NULL,
    CONSTRAINT ck_popups_image_url CHECK (image_url ~ '^(https://|http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/)'),
    CONSTRAINT ck_popups_link_https CHECK (link_url IS NULL OR link_url ~ '^https://'),
    CONSTRAINT ck_popups_date_order CHECK (end_date >= start_date)
);
CREATE INDEX IF NOT EXISTS idx_popups_active_range
    ON popups (start_date, end_date) WHERE deleted_at IS NULL AND is_active;
CREATE OR REPLACE TRIGGER trg_popups_updated_at
    BEFORE UPDATE ON popups FOR EACH ROW EXECUTE FUNCTION set_updated_at();
