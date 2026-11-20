// ----------------------------------------------------------------------
// Flyway 실행기의 순수 함수 — 인자 해석 · conf 파싱 · docker 인자 조립.
// 부수효과(파일 읽기·프로세스 실행)는 run-flyway.mjs 에만 둔다(flyway-args.test.mjs 로 검증).
// ----------------------------------------------------------------------

export const ENVIRONMENTS = ['local', 'development', 'production'];
export const COMMANDS = ['migrate', 'info', 'validate'];

/** Flyway 공식 이미지. 2026-11-19 기준 최신 13.12.2(develop §1). */
export const FLYWAY_IMAGE = 'flyway/flyway:13.12.2-alpine';

/** production 마이그레이션 전에 사용자가 그대로 입력해야 하는 확인 문구 */
export const PRODUCTION_CONFIRM_PHRASE = 'production 마이그레이션';

export const USAGE = [
  '사용법: pnpm <migrate|migrate:info|migrate:validate> [local|development|production]',
  '  환경을 생략하면 local 로 실행합니다.',
  '  접속 정보는 flyway-<환경>.conf 에서 읽습니다(flyway-<환경>.conf.example 을 복사).',
].join('\n');

/**
 * [command, env?] 를 해석한다. 환경 생략 시 local.
 * @returns {{ ok: true, command: string, env: string } | { ok: false, error: string }}
 */
export function parseFlywayArgs(argv) {
  const [command, env = 'local', ...rest] = argv;
  if (!COMMANDS.includes(command)) {
    return { ok: false, error: `알 수 없는 명령입니다: ${command ?? '(없음)'}` };
  }
  if (!ENVIRONMENTS.includes(env)) {
    return { ok: false, error: `알 수 없는 환경입니다: ${env}` };
  }
  if (rest.length > 0) {
    return { ok: false, error: `인자가 너무 많습니다: ${rest.join(' ')}` };
  }
  return { ok: true, command, env };
}

/** key=value conf 텍스트 → 객체. 빈 줄·# 주석은 건너뛴다. */
export function parseConf(text) {
  const conf = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    conf[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  return conf;
}

/** 컨테이너 안에서 호스트의 localhost DB 에 닿도록 주소를 바꾼다. */
export function toContainerJdbcUrl(url) {
  return url.replace(
    /^jdbc:postgresql:\/\/(localhost|127\.0\.0\.1)([:/])/,
    'jdbc:postgresql://host.docker.internal$2'
  );
}

/** 자리표시자(<…>)가 남은 값이 있으면 그 키 목록을 돌려준다. */
export function findPlaceholderKeys(conf) {
  return Object.entries(conf)
    .filter(([, value]) => /<[^>]+>/.test(value))
    .map(([key]) => key);
}

/**
 * docker run 인자를 만든다. 비밀번호는 인자로 넘기지 않고 -e FLYWAY_PASSWORD 로만 전달한다
 * (프로세스 목록·셸 기록에 남지 않게).
 */
export function buildDockerArgs({ command, conf, sqlDir, hasPassword }) {
  const flywayArgs = Object.entries(conf)
    .filter(([key, value]) => key !== 'flyway.password' && value !== '')
    .map(([key, value]) => {
      const name = key.replace(/^flyway\./, '');
      const finalValue = name === 'url' ? toContainerJdbcUrl(value) : value;
      return `-${name}=${finalValue}`;
    });

  return [
    'run',
    '--rm',
    '--add-host=host.docker.internal:host-gateway',
    '-v',
    `${sqlDir}:/flyway/sql:ro`,
    ...(hasPassword ? ['-e', 'FLYWAY_PASSWORD'] : []),
    FLYWAY_IMAGE,
    ...flywayArgs,
    command,
  ];
}
