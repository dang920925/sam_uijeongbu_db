// Flyway 실행기 순수 함수 테스트 — `pnpm test` (node:test)
import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  buildDockerArgs,
  findPlaceholderKeys,
  FLYWAY_IMAGE,
  parseConf,
  parseFlywayArgs,
  toContainerJdbcUrl,
} from './flyway-args.mjs';

describe('parseFlywayArgs', () => {
  it('환경을 생략하면 local 로 해석한다', () => {
    assert.deepEqual(parseFlywayArgs(['migrate']), {
      ok: true,
      command: 'migrate',
      env: 'local',
    });
  });

  it('production 을 그대로 받는다', () => {
    assert.deepEqual(parseFlywayArgs(['info', 'production']), {
      ok: true,
      command: 'info',
      env: 'production',
    });
  });

  it('허용 목록 밖 환경 이름을 거부한다', () => {
    const result = parseFlywayArgs(['migrate', 'prod']);
    assert.equal(result.ok, false);
    assert.match(result.error, /알 수 없는 환경/);
  });

  it('허용 목록 밖 명령(clean)을 거부한다', () => {
    const result = parseFlywayArgs(['clean', 'local']);
    assert.equal(result.ok, false);
    assert.match(result.error, /알 수 없는 명령/);
  });

  it('남는 인자가 있으면 거부한다', () => {
    assert.equal(parseFlywayArgs(['migrate', 'local', 'x']).ok, false);
  });
});

describe('parseConf', () => {
  it('주석·빈 줄을 건너뛰고 key=value 를 읽는다', () => {
    const conf = parseConf('# 주석\n\nflyway.url=jdbc:x?a=b\nflyway.password=\n');
    assert.deepEqual(conf, { 'flyway.url': 'jdbc:x?a=b', 'flyway.password': '' });
  });

  it('빈 텍스트는 빈 객체다', () => {
    assert.deepEqual(parseConf(''), {});
  });
});

describe('toContainerJdbcUrl', () => {
  it('localhost 를 host.docker.internal 로 바꾼다', () => {
    assert.equal(
      toContainerJdbcUrl('jdbc:postgresql://localhost:5432/db'),
      'jdbc:postgresql://host.docker.internal:5432/db'
    );
  });

  it('원격 호스트는 그대로 둔다', () => {
    const url = 'jdbc:postgresql://db.test.example:5432/db?sslmode=require';
    assert.equal(toContainerJdbcUrl(url), url);
  });
});

describe('findPlaceholderKeys', () => {
  it('<…> 자리표시자가 남은 키를 찾는다', () => {
    assert.deepEqual(
      findPlaceholderKeys({ 'flyway.url': 'jdbc:postgresql://<호스트>/db', 'flyway.user': 'u' }),
      ['flyway.url']
    );
  });

  it('모두 채워졌으면 빈 배열이다', () => {
    assert.deepEqual(findPlaceholderKeys({ 'flyway.user': 'u' }), []);
  });
});

describe('buildDockerArgs', () => {
  const conf = {
    'flyway.url': 'jdbc:postgresql://localhost:5432/db',
    'flyway.user': 'postgres',
    'flyway.password': 'should-not-appear',
    'flyway.baselineVersion': '0',
  };

  it('비밀번호를 인자에 넣지 않고 FLYWAY_PASSWORD 환경변수로만 넘긴다', () => {
    const args = buildDockerArgs({ command: 'migrate', conf, sqlDir: '/s', hasPassword: true });
    assert.ok(!args.join(' ').includes('should-not-appear'));
    assert.ok(args.includes('FLYWAY_PASSWORD'));
  });

  it('이미지 · 변환된 url · 명령 순서로 조립한다', () => {
    const args = buildDockerArgs({ command: 'info', conf, sqlDir: '/s', hasPassword: false });
    const imageIndex = args.indexOf(FLYWAY_IMAGE);
    assert.ok(imageIndex > 0);
    assert.ok(args.includes('-url=jdbc:postgresql://host.docker.internal:5432/db'));
    assert.equal(args.at(-1), 'info');
    assert.ok(!args.includes('-e'));
  });
});
