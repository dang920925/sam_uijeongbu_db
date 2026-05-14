# SAM Uijeongbu DB (샘 의정부 데이터베이스 관리)

이 프로젝트는 SAM 의정부 프로젝트를 위한 데이터베이스 스키마 및 마이그레이션을 관리합니다. Docker와 Flyway를 사용하여 로컬 환경에서 손쉽게 데이터베이스를 구축할 수 있습니다.

---

## 1. 사전 준비 (Prerequisites)

아무것도 설치되어 있지 않은 상태라면 아래 도구들을 순서대로 설치해야 합니다.

### 1-1. Docker 설치
데이터베이스를 내 컴퓨터에서 직접 설치하지 않고 컨테이너 기술로 실행하기 위해 필요합니다.
- **[Docker Desktop 다운로드](https://www.docker.com/products/docker-desktop/)** 사이트에 접속하여 본인의 OS(Windows/Mac)에 맞는 버전을 설치하세요.
- 설치 후 실행하여 "Docker Desktop is running" 상태가 되었는지 확인합니다.

### 1-2. Homebrew 설치 (Mac 사용자 권장)
다양한 개발 도구를 쉽게 설치하기 위한 관리 도구입니다.
- 터미널(Terminal.app)을 열고 아래 명령어를 입력하세요:
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

### 1-3. Flyway 및 Make 설치
DB 마이그레이션 실행을 위해 필요합니다. 터미널에서 아래 명령어를 입력하세요.

**Mac:**
```bash
brew install flyway make
```

**Windows:**
- [Flyway 공식 사이트](https://flywaydb.org/download/)에서 다운로드하거나, `choco install flyway` (Chocolatey 사용자)를 사용하세요.
- 기본적으로 Windows는 `make`가 없으므로 터미널 명령어 대신 `Makefile`의 내용을 직접 실행해야 할 수 있습니다.

---

## 2. 시작하기 (Getting Started)

### 2-1. 데이터베이스 서버 실행
프로젝트 폴더에서 터미널을 열고 아래 명령어를 입력하여 PostgreSQL 데이터베이스를 실행합니다.
```bash
docker-compose up -d
```
> **참고:** 처음 실행 시 이미지를 다운로드하느라 시간이 조금 걸릴 수 있습니다.

### 2-2. 데이터베이스 스키마 반영 (Migration)
데이터베이스가 켜진 상태에서 테이블과 상태값(ENUM)을 생성하기 위해 마이그레이션을 실행합니다.
```bash
make migrate-local
```
이 작업이 완료되면 모든 테이블이 생성됩니다.

---

## 3. 주요 명령어 (Commands)

| 명령어 | 설명 |
| :--- | :--- |
| `make migrate-local` | 최신 스키마 변경사항을 DB에 반영합니다. |
| `make clean-local` | DB의 모든 데이터를 삭제하고 스키마를 초기화합니다. (주의!) |
| `make reset-local` | DB를 초기화하고 처음부터 다시 마이그레이션을 수행합니다. |
| `make repair-local` | 마이그레이션 이력이 꼬였을 때 복구합니다. |
| `docker-compose stop` | DB 서버를 잠시 중단합니다. |
| `docker-compose down` | DB 컨테이너를 완전히 삭제합니다. (데이터는 볼륨에 보존됩니다.) |

---

## 4. 데이터베이스 접속 정보 (Local)

직접 DB 툴(DBeaver, TablePlus 등)로 접속할 때 사용하세요.

- **Host:** `localhost`
- **Port:** `5435`
- **Database:** `sam_uijeongbu`
- **Username:** `sam_user`
- **Password:** `sam_password123!`

---

## 5. 프로젝트 구조

- `/sql`: 데이터베이스 스키마 변경 이력 파일들 (`V1__init_schema.sql` 등)
- `docker-compose.yml`: 로컬 DB 서버 설정 정보
- `flyway.conf`: 마이그레이션 공통 설정
- `Makefile`: 복잡한 명령어를 짧게 줄여놓은 스크립트 파일
