#!/usr/bin/env node
// ----------------------------------------------------------------------
// Flyway 실행기 — `pnpm migrate [local|development|production]`
// Flyway 를 따로 설치하지 않고 공식 docker 이미지로 실행한다.
// production 은 확인 문구를 입력해야 진행한다(운영 DB 보호).
// ----------------------------------------------------------------------
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';

import {
  buildDockerArgs,
  findPlaceholderKeys,
  parseConf,
  parseFlywayArgs,
  PRODUCTION_CONFIRM_PHRASE,
  USAGE,
} from './flyway-args.mjs';

function fail(message) {
  console.error(`[migrate] ${message}\n\n${USAGE}`);
  process.exit(1);
}

async function confirmProduction() {
  if (!process.stdin.isTTY) {
    fail('production 마이그레이션은 터미널에서 확인 문구를 입력해야 합니다.');
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const answer = await rl.question(
    `운영 DB 에 적용합니다. 계속하려면 "${PRODUCTION_CONFIRM_PHRASE}" 를 입력하세요: `
  );
  rl.close();
  if (answer.trim() !== PRODUCTION_CONFIRM_PHRASE) {
    fail('확인 문구가 일치하지 않아 중단합니다.');
  }
}

async function main() {
  const parsed = parseFlywayArgs(process.argv.slice(2));
  if (!parsed.ok) fail(parsed.error);
  const { command, env } = parsed;

  const confPath = resolve(process.cwd(), `flyway-${env}.conf`);
  if (!existsSync(confPath)) {
    fail(`접속 설정 파일이 없습니다: flyway-${env}.conf (flyway-${env}.conf.example 을 복사해 채우세요)`);
  }
  const conf = parseConf(readFileSync(confPath, 'utf8'));
  const placeholders = findPlaceholderKeys(conf);
  if (placeholders.length > 0) {
    fail(`flyway-${env}.conf 에 채우지 않은 값이 있습니다: ${placeholders.join(', ')}`);
  }

  if (env === 'production' && command === 'migrate') {
    await confirmProduction();
  }

  const args = buildDockerArgs({
    command,
    conf,
    sqlDir: resolve(process.cwd(), 'sql'),
    hasPassword: Boolean(process.env.FLYWAY_PASSWORD),
  });
  console.log(`[migrate] ${env} · flyway ${command}`);
  const result = spawnSync('docker', args, { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

void main();
