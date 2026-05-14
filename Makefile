.PHONY: migrate-local clean-local repair-local reset-local

# 로컬 환경
migrate-local:
	flyway migrate -configFiles=flyway.conf,flyway-local.conf

clean-local:
	flyway clean -configFiles=flyway.conf,flyway-local.conf

repair-local:
	flyway repair -configFiles=flyway.conf,flyway-local.conf

# 로컬 전체 재실행
reset-local: clean-local migrate-local
