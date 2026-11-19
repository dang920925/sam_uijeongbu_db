<!-- BEGIN:flyway-agent-rules -->
# SAM 의정부 DB 저장소 에이전트 지침

## 0. 사용자 언어
주석·커밋·문서는 한국어, 식별자(테이블·컬럼)는 영어 snake_case.

## 1. 프로젝트 개요
SAM 의정부 서비스의 **스키마 유일한 정본**(Flyway SQL). 서버 `sam_uijeongbu_server` 의 `prisma/schema.prisma` 는 여기서 `prisma db pull` 한 파생물이다. 운영 DB 는 Supabase(Postgres 17, 서울), 로컬은 docker `postgres:17.12-alpine`(127.0.0.1:4110, trust).

## 2. 기술 스택
Flyway 13.12.2(docker 공식 이미지 — 설치 불필요) · PostgreSQL 17 · Node 24(실행기 스크립트·node:test) · pnpm 10.

## 3. 코드 스타일
SQL 키워드 대문자, 4칸 들여쓰기, 제약 이름 `ck_/uq_/pk_/idx_<테이블>_<내용>`. 파일 머리 주석에 **배경 · 범위 · 안전성**.

## 4. 프로젝트 구조
```
sql/V1__init_schema.sql · V1_0_N__<설명>.sql   마이그레이션(번호 +1)
scripts/run-flyway.mjs · flyway-args.mjs       pnpm migrate[:info|:validate] <env> 실행기(+ test)
scripts/check-security.sql · run-check-security.mjs   권한·RLS 점검(0행 = 통과)
scripts/verify-supabase-like.mjs                Supabase 흉내 DB(anon·authenticated·storage)에서 전체 적용 검증
docker/initdb/01-roles.sql                      로컬 첫 기동: sam_app · sam_api(로그인, trust)
flyway-<env>.conf.example                       접속 설정 예시(.conf 는 gitignore, 비밀번호는 FLYWAY_PASSWORD)
docs/ERD.md                                     ERD + 마이그레이션 목록
```

## 5. 아키텍처 기본 원칙
| 규칙 | 내용 |
| --- | --- |
| 열거값 | VARCHAR + CHECK(UPPER_SNAKE). DB enum 금지 |
| 다중값 | 조인 테이블(jsonb 는 payload 자리만) |
| 시각 | TIMESTAMPTZ(UTC 저장), 날짜만 DATE, 벽시계 TIME(KST) |
| 삭제 | 관리 콘텐츠는 `deleted_at` 소프트 삭제. 신청서는 보유기간 뒤 영구 삭제(파기) |
| FK | 모두 인덱스(유니크·PK 가 겸하면 생략), ON DELETE 를 의도대로 |
| URL | 스킴 CHECK(이미지: https 또는 루프백 http · 외부 링크: https 만) |
| 권한 | 런타임 `sam_app` 은 필요한 DML 만. **새 테이블은 같은 마이그레이션에서 ENABLE RLS + `sam_app_all` 정책 + GRANT** 를 넣는다(V1_0_2 끝 검사·`pnpm verify:security` 가 잡는다) |
| Supabase 전용 객체 | `to_regclass`/`to_regrole` 조건부 SQL 로 — 로컬 Postgres 에서는 건너뛴다(V1_0_3 참고) |

## 6. 핵심 패턴
- 멱등: `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION/TRIGGER`, 역할·정책은 DO 블록 존재 확인.
- 불변·한 방향 데이터는 트리거로 DB 가 막는다(V1 `applications_guard_update`).
- ⚠ 2026-11-19: Flyway 가 잡은 이력 테이블 잠금 때문에 마이그레이션 안에서 `flyway_schema_history` 를 ALTER 하면 멈춘다 — 하지 않는다.

## 7. 타입 안전성
금액·수량이 생기면 NUMERIC. 길이 상한은 VARCHAR(n) 또는 CHECK(char_length).

## 8. 네이밍 규칙
테이블 snake_case 복수형, 컬럼 snake_case, 마이그레이션 `V1_0_N__설명_snake_case.sql`.

## 9. 커밋 · 브랜치 · 푸시
한국어 Conventional Commits(`feat(prisma): …` 등), 스키마 변경과 로직 변경 분리. 에이전트는 push 하지 않는다.

## 10. 테스트 작성 규칙
`pnpm test`(실행기·SQL 동기화), `pnpm migrate local` 2회(멱등), `pnpm verify:security local`(0행), `pnpm verify:supabase-like`(Supabase 흉내 전체 적용). 서버 E2E 가 실제 권한·트리거를 확인한다.

## 11. 위반 자가 점검 체크리스트
- [ ] 이미 적용된 V 파일을 고치지 않았는가(운영 적용 후에는 새 V 파일로만)?
- [ ] 머리 주석에 배경·범위·안전성이 있는가? 다시 실행해도 안전한가?
- [ ] 새 테이블에 RLS·정책·GRANT·FK 인덱스·CHECK 가 있는가?
- [ ] 서버 `pnpm prisma:pull local` · `docs/ERD.md` 를 함께 갱신했는가?
<!-- END:flyway-agent-rules -->
