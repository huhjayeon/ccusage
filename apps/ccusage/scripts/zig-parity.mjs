import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import process from 'node:process';

const packageRoot = new URL('..', import.meta.url).pathname;
const repoRoot = new URL('../../..', import.meta.url).pathname;
const fixture = mkdtempSync(join(tmpdir(), 'ccusage-zig-parity-'));

const claudeDir = join(fixture, 'claude');
const projectDirA = join(claudeDir, 'projects', 'project-a');
const projectDirB = join(claudeDir, 'projects', 'project-b');

const recordsA = [
	{
		timestamp: '2025-01-01T10:00:00.000Z',
		sessionId: 'session-a',
		version: '1.0.0',
		message: {
			id: 'msg-a1',
			model: 'claude-sonnet-4-20250514',
			usage: {
				input_tokens: 1000,
				output_tokens: 200,
				cache_creation_input_tokens: 50,
				cache_read_input_tokens: 25,
			},
		},
		requestId: 'req-a1',
		costUSD: 0.01,
	},
	{
		timestamp: '2025-01-02T10:00:00.000Z',
		sessionId: 'session-a',
		version: '1.0.1',
		message: {
			id: 'msg-a2',
			model: 'claude-opus-4-20250514',
			usage: {
				input_tokens: 2000,
				output_tokens: 400,
				cache_creation_input_tokens: 100,
				cache_read_input_tokens: 50,
			},
		},
		requestId: 'req-a2',
		costUSD: 0.08,
	},
];

const recordsB = [
	{
		timestamp: '2025-01-08T10:00:00.000Z',
		sessionId: 'session-b',
		version: '1.0.2',
		message: {
			id: 'msg-b1',
			model: 'claude-haiku-4-5-20251001',
			usage: {
				input_tokens: 300,
				output_tokens: 120,
				cache_creation_input_tokens: 0,
				cache_read_input_tokens: 40,
			},
		},
		requestId: 'req-b1',
		costUSD: 0.004,
	},
	{
		timestamp: '2025-01-08T11:00:00.000Z',
		sessionId: 'session-b',
		version: '1.0.3',
		isApiErrorMessage: true,
		message: {
			id: 'msg-b2',
			model: 'claude-haiku-4-5-20251001',
			content: [{ text: 'Claude AI usage limit reached|1736337600' }],
			usage: {
				input_tokens: 10,
				output_tokens: 0,
				cache_creation_input_tokens: 0,
				cache_read_input_tokens: 0,
			},
		},
		requestId: 'req-b2',
		costUSD: 0.001,
	},
];

function writeJsonl(path, records) {
	writeFileSync(path, `${records.map((record) => JSON.stringify(record)).join('\n')}\n`);
}

function run(command, args) {
	const result = spawnSync(command, args, {
		cwd: packageRoot,
		env: {
			...process.env,
			CLAUDE_CONFIG_DIR: claudeDir,
			TZ: 'UTC',
		},
		encoding: 'utf8',
	});
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(' ')} failed\n${result.stderr}`);
	}
	return JSON.parse(result.stdout);
}

function runText(command, args) {
	return stripAnsi(runRaw(command, args, { FORCE_COLOR: '1' }));
}

function runRaw(command, args, extraEnv = {}) {
	return runProcess(command, args, extraEnv).stdout;
}

function runProcess(command, args, extraEnv = {}) {
	const result = spawnSync(command, args, {
		cwd: packageRoot,
		env: {
			...process.env,
			CLAUDE_CONFIG_DIR: claudeDir,
			COLUMNS: '120',
			TZ: 'UTC',
			...extraEnv,
		},
		encoding: 'utf8',
	});
	if (result.status !== 0) {
		throw new Error(`${command} ${args.join(' ')} failed\n${result.stderr}`);
	}
	return result;
}

function stripAnsi(value) {
	let output = '';
	for (let index = 0; index < value.length; index++) {
		if (value.charCodeAt(index) !== 27 || value[index + 1] !== '[') {
			output += value[index];
			continue;
		}
		index += 2;
		while (index < value.length) {
			const code = value.charCodeAt(index);
			if (code >= 0x40 && code <= 0x7E) {
				break;
			}
			index++;
		}
	}
	return output;
}

function normalize(value) {
	if (Array.isArray(value)) {
		return value.map(normalize);
	}
	if (value != null && typeof value === 'object') {
		return Object.fromEntries(
			Object.entries(value)
				.filter(([key]) => key !== 'id')
				.map(([key, child]) => [key, normalize(child)])
				.sort(([a], [b]) => a.localeCompare(b)),
		);
	}
	if (typeof value === 'number') {
		return Number(value.toFixed(12));
	}
	return value;
}

try {
	mkdirSync(projectDirA, { recursive: true });
	mkdirSync(projectDirB, { recursive: true });
	writeJsonl(join(projectDirA, 'session-a.jsonl'), recordsA);
	writeJsonl(join(projectDirB, 'session-b.jsonl'), recordsB);

	const jsCli = join(packageRoot, 'dist', 'index.js');
	const zigCli = join(repoRoot, 'zig-out', 'bin', 'ccusage');
	const cases = [
		['daily', ['daily', '--offline', '--json', '--mode', 'display']],
		[
			'daily filtered desc',
			[
				'daily',
				'--offline',
				'--json',
				'--mode',
				'display',
				'--since',
				'20250102',
				'--until',
				'20250108',
				'--order',
				'desc',
			],
		],
		['daily instances', ['daily', '--offline', '--json', '--mode', 'display', '--instances']],
		[
			'daily project',
			['daily', '--offline', '--json', '--mode', 'display', '--project', 'project-a'],
		],
		['weekly', ['weekly', '--offline', '--json', '--mode', 'display']],
		[
			'weekly monday',
			['weekly', '--offline', '--json', '--mode', 'display', '--start-of-week', 'monday'],
		],
		['monthly', ['monthly', '--offline', '--json', '--mode', 'display']],
		['session', ['session', '--offline', '--json', '--mode', 'display']],
		['session id', ['session', '--offline', '--json', '--mode', 'display', '--id', 'session-a']],
		['blocks', ['blocks', '--offline', '--json', '--mode', 'display']],
		[
			'blocks custom duration',
			['blocks', '--offline', '--json', '--mode', 'display', '--session-length', '2'],
		],
	];

	for (const [name, args] of cases) {
		const js = normalize(run(process.execPath, [jsCli, ...args]));
		const zig = normalize(run(zigCli, args));
		if (JSON.stringify(js) !== JSON.stringify(zig)) {
			console.error(`Parity failed for ${name}`);
			console.error('JS:', JSON.stringify(js, null, 2));
			console.error('Zig:', JSON.stringify(zig, null, 2));
			process.exit(1);
		}
		console.log(`ok ${name}`);
	}

	const blocks = run(zigCli, ['blocks', '--offline', '--json', '--mode', 'display']);
	if (!blocks.blocks.some((block) => block.usageLimitResetTime === '2025-01-08T12:00:00.000Z')) {
		console.error('Blocks reset time smoke failed for Zig');
		console.error(JSON.stringify(blocks, null, 2));
		process.exit(1);
	}

	const jsInstances = runText(process.execPath, [
		jsCli,
		'daily',
		'--offline',
		'--mode',
		'display',
		'--instances',
		'--project-aliases',
		'project-b=Project B',
	]);
	const zigInstances = runText(zigCli, [
		'daily',
		'--offline',
		'--mode',
		'display',
		'--instances',
		'--project-aliases',
		'project-b=Project B',
	]);
	for (const [name, output] of [
		['JS table instances', jsInstances],
		['Zig table instances', zigInstances],
	]) {
		if (!output.includes('Project:') || !output.includes('Project B')) {
			console.error(`Table smoke failed for ${name}`);
			console.error(output);
			process.exit(1);
		}
	}
	const zigBreakdown = runText(zigCli, ['daily', '--offline', '--mode', 'display', '--breakdown']);
	if (!zigBreakdown.includes('└─ sonnet-4')) {
		console.error('Table smoke failed for Zig breakdown labels');
		console.error(zigBreakdown);
		process.exit(1);
	}
	const zigSession = runText(zigCli, ['session', '--offline', '--mode', 'display']);
	if (!zigSession.includes('Last') || !zigSession.includes('Activity')) {
		console.error('Table smoke failed for Zig session last activity column');
		console.error(zigSession);
		process.exit(1);
	}
	const zigNoColor = runRaw(zigCli, ['daily', '--offline', '--mode', 'display', '--no-color'], {
		FORCE_COLOR: '1',
	});
	if (zigNoColor.includes('\x1B[')) {
		console.error('Table smoke failed for Zig --no-color');
		console.error(zigNoColor);
		process.exit(1);
	}
	const zigDebug = runProcess(zigCli, [
		'daily',
		'--offline',
		'--mode',
		'display',
		'--debug',
		'--debug-samples',
		'1',
	]);
	if (!zigDebug.stderr.includes('Pricing Mismatch Debug Report')) {
		console.error('Table smoke failed for Zig debug report');
		console.error(zigDebug.stderr);
		process.exit(1);
	}
	console.log('ok table smoke');
} finally {
	rmSync(fixture, { force: true, recursive: true });
}
