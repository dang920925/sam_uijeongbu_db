-- ----------------------------------------------------------------------
-- 로컬 DB 첫 기동 시 1회: API 런타임 로그인 계정 생성
-- sam_app(NOLOGIN) 에 V1_0_1 마이그레이션이 테이블별 DML 을 주고, V1_0_2 가 RLS 정책을 준다.
-- sam_api 는 그 멤버로 로그인만 한다 — 로컬 trust 인증이라 비밀번호 없음.
-- development·production 에서는 db README "런타임 계정" 절대로 비밀번호를 붙여 직접 만든다.
-- ----------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sam_app') THEN
    CREATE ROLE sam_app NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sam_api') THEN
    CREATE ROLE sam_api LOGIN IN ROLE sam_app;
  END IF;
END
$$;
