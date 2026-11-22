# SAM 의정부 DB (Flyway — 스키마 정본)

## 1. 바로 실행 (local)

```bash
# 준비물: Docker · Node 24 · pnpm 10 (Flyway 는 docker 이미지로 실행 — 설치 불필요)
cp flyway-local.conf.example flyway-local.conf
pnpm db:up                  # postgres:17.12 · 127.0.0.1:4110 · trust · sam_app/sam_api 역할 생성
pnpm migrate local          # V1 ~ V1_0_12 적용(다시 실행해도 "up to date")
pnpm migrate:info local
pnpm verify:security local  # 권한·RLS 위반 0행이면 통과
pnpm verify:supabase-like   # Supabase 흉내 DB(anon·authenticated·storage)에서 전체 적용·검사
pnpm test                   # 실행기·SQL 동기화 테스트
```

## 2. 환경별 명령 (마지막 인자 `local|development|production`, 생략 시 local)

| 명령 | 설명 |
| --- | --- |
| `pnpm migrate <env>` | Flyway migrate. production 은 확인 문구 입력 필요 |
| `pnpm migrate:info <env>` · `pnpm migrate:validate <env>` | 이력 · 검증 |
| `pnpm verify:security <env>` | 권한·RLS 점검. development·production 은 `CHECK_DATABASE_URL`(마이그레이션 계정 postgres:// 주소) 필요 |

접속 정보는 `flyway-<env>.conf`(예시 복사), 비밀번호는 `FLYWAY_PASSWORD` 환경변수로만 넣는다.

## 3. Supabase 적용 순서 (운영·공유 개발 — 사용자가 실행)

1. Supabase 새 프로젝트(서울 `ap-northeast-2`) — Enforce SSL 켬, Data API 끔.
2. `flyway-production.conf` — 세션 풀러 5432 주소(`?sslmode=require`)와 `postgres.<project-ref>` 계정. `FLYWAY_PASSWORD=<Database password>`.
3. `pnpm migrate production` → V1(스키마) → V1_0_1(sam_app) → V1_0_2(RLS·anon 회수·끝 검사) → V1_0_3(storage 버킷 media — Supabase 에만 적용) → V1_0_4(예매 1단계) → V1_0_5(일정 취소) → V1_0_6(신청 관심 작품·연락·진행) → V1_0_7(새 예매 푸시 구독) — 여기까지 v1.2.0 → V1_0_8(팀 계정·연습실 예약, T-PR) → V1_0_9(좌석 지정·초대자 구분, T-SEAT) → V1_0_10(배역·캐스팅·크레딧·연출진 연혁, R3) → V1_0_11(단원 공개 동의일, U39) — v1.3.0 에서 운영 기준 연속 번호로 정리. → V1_0_12(초대 유형별 가격, U41) — v1.3.1.
   - **V1_0_4 적용 전 확인(운영에 이미 회차가 있다)**: SQL Editor 에서 아래가 0행이어야 한다. 행이 있으면 V1_0_4 가 "V1_0_4 중단 — 같은 공연·날짜·시작 시각의 회차가 …" 로 롤백한다(데이터는 그대로) — 중복 회차를 정리한 뒤 다시 적용한다.
     ```sql
     SELECT performance_id, show_date, start_time, count(*) FROM shows GROUP BY 1, 2, 3 HAVING count(*) > 1;
     ```
4. **런타임 계정**(SQL Editor, 마이그레이션 계정으로 1회):
   ```sql
   CREATE ROLE sam_api LOGIN PASSWORD '<openssl rand -base64 32 로 만든 값>' IN ROLE sam_app;
   ```
   서버 `DATABASE_URL` = `postgresql://sam_api.<project-ref>:<그 비밀번호>@<풀러 호스트>:6543/postgres?sslmode=require&uselibpqcompat=true`(트랜잭션 풀러).
   ⚠ 사용자 정의 역할의 풀러 로그인은 추정(E-04) — 실패하면 back-end.md §12 의 대안을 따른다.
5. (선택, Security Advisor 경고 제거) SQL Editor 에서 `ALTER TABLE public.flyway_schema_history ENABLE ROW LEVEL SECURITY;`
6. `CHECK_DATABASE_URL=<마이그레이션 계정 주소> pnpm verify:security production` → 위반 0건. 그다음 서버 배포.
7. Storage → Buckets 에서 `media` 가 public · 10MB · jpeg/png/webp 인지 확인(대시보드에서 바꾸지 않는다 — 바꾸려면 새 마이그레이션).

## 4. 문서
`docs/ERD.md` · `AGENTS.md`(규칙)
