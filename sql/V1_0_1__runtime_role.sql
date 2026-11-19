-- ----------------------------------------------------------------------
-- V1_0_1: API 런타임 역할 sam_app (최소 권한)
-- 배경: 마이그레이션 계정(테이블 소유자 — 로컬·Supabase 모두 postgres)과 API 런타임 계정을 나눈다
--       (가이드 A17.1 "최소 권한(DB)", 기획 develop §4 보안, 추정 E-04).
-- 범위: NOLOGIN 역할 sam_app 을 만들고 테이블별로 필요한 DML 만 준다.
--       - DELETE 는 영구 삭제가 필요한 테이블에만: applications(보유기간 파기) · classes(반 삭제) ·
--         class_days · performance_detail_images · actor_filmographies(전체 교체).
--         그 밖의 관리 콘텐츠는 소프트 삭제(deleted_at)라 DELETE 를 주지 않는다.
--       - admins: SELECT · UPDATE 만(잠금·세션 버전). 계정 행은 관리자 생성 스크립트(FN-21)가 마이그레이션 계정으로 만든다.
--       - shows: SELECT 만(관리 UI 없음 — FN-28 제외).
--       - TRUNCATE · REFERENCES · TRIGGER 는 주지 않는다. flyway_schema_history 는 권한 없음.
--       실제 로그인 계정은 환경마다 따로 만든다(비밀번호가 있으므로 마이그레이션에 넣지 않는다):
--         CREATE ROLE sam_api LOGIN PASSWORD '<플랫폼 시크릿>' IN ROLE sam_app;   -- db README "런타임 계정"
--       로컬 docker 는 docker/initdb/01-roles.sql 이 trust 인증용 sam_api 를 만든다.
-- 안전성: 역할 생성은 DO 블록으로 멱등, GRANT 는 반복 실행해도 같은 결과. 기존 행 변경 없음.
--         Supabase 의 마이그레이션 계정(postgres)은 CREATEROLE 을 가진다.
-- ----------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sam_app') THEN
        CREATE ROLE sam_app NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO sam_app;

-- 읽기 + 쓰기(소프트 삭제 테이블)
GRANT SELECT, INSERT, UPDATE ON
    performances, members, actor_profiles, galleries, schedules, staff, popups
    TO sam_app;

-- 영구 삭제가 필요한 테이블
GRANT SELECT, INSERT, UPDATE, DELETE ON
    applications, classes, class_days, performance_detail_images, actor_filmographies
    TO sam_app;

-- 관리자: 잠금·세션 버전 갱신만
GRANT SELECT, UPDATE ON admins TO sam_app;

-- 회차: 읽기만
GRANT SELECT ON shows TO sam_app;
