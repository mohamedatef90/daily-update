const fs = require('fs');
const path = require('path');
const os = require('os');
const { scanForRepositories, isValidDirectory, SKIP_DIRS } = require('../src/scanner');
const { expandPath } = require('../src/pathUtils');
const { resolvePathPattern, loadDetectors, detectOne, scanDetectors } = require('../src/detectors');

// Test helpers
function createTestDirectory(basePath, structure) {
  for (const [name, content] of Object.entries(structure)) {
    const fullPath = path.join(basePath, name);
    if (typeof content === 'object') {
      fs.mkdirSync(fullPath, { recursive: true });
      createTestDirectory(fullPath, content);
    } else {
      fs.mkdirSync(path.dirname(fullPath), { recursive: true });
      fs.writeFileSync(fullPath, content || '');
    }
  }
}

function cleanup(dirPath) {
  if (fs.existsSync(dirPath)) {
    fs.rmSync(dirPath, { recursive: true, force: true });
  }
}

// Tests
function testIsValidDirectory() {
  console.log('Testing isValidDirectory...');

  const validDir = os.tmpdir();
  const invalidDir = path.join(os.tmpdir(), 'non-existent-dir-' + Date.now());

  if (!isValidDirectory(validDir)) {
    throw new Error('isValidDirectory failed for valid directory');
  }

  if (isValidDirectory(invalidDir)) {
    throw new Error('isValidDirectory returned true for invalid directory');
  }

  console.log('✓ isValidDirectory passed');
}

function testScanForRepositories() {
  console.log('Testing scanForRepositories...');

  const testRoot = path.join(os.tmpdir(), 'daily-update-test-' + Date.now());

  try {
    createTestDirectory(testRoot, {
      'repo1': {
        '.git': {
          'HEAD': 'ref: refs/heads/main'
        },
        'src': {
          'index.js': 'console.log("hello");'
        }
      },
      'projects': {
        'repo2': {
          '.git': {
            'HEAD': 'ref: refs/heads/main'
          }
        },
        'repo3': {
          '.git': {
            'HEAD': 'ref: refs/heads/main'
          },
          'nested': {
            'file.txt': 'test'
          }
        }
      },
      'node_modules': {
        'some-package': {
          '.git': {
            'HEAD': 'ref: refs/heads/main'
          }
        }
      },
      'regular-folder': {
        'file.txt': 'not a repo'
      }
    });

    const repos = scanForRepositories(testRoot, 4);

    if (repos.length !== 3) {
      throw new Error(`Expected 3 repos, found ${repos.length}: ${repos.join(', ')}`);
    }

    const repo1Path = path.join(testRoot, 'repo1');
    const repo2Path = path.join(testRoot, 'projects', 'repo2');
    const repo3Path = path.join(testRoot, 'projects', 'repo3');

    if (!repos.includes(repo1Path)) throw new Error('Missing repo1');
    if (!repos.includes(repo2Path)) throw new Error('Missing repo2');
    if (!repos.includes(repo3Path)) throw new Error('Missing repo3');

    const nodeModulesRepo = path.join(testRoot, 'node_modules', 'some-package');
    if (repos.includes(nodeModulesRepo)) {
      throw new Error('node_modules repo should be skipped');
    }

    createTestDirectory(testRoot, {
      'level1': {
        'level2': {
          'level3': {
            'level4': {
              'level5': {
                '.git': {
                  'HEAD': 'ref: refs/heads/main'
                }
              }
            }
          }
        }
      }
    });

    const reposDepth2 = scanForRepositories(testRoot, 2);
    const level5Path = path.join(testRoot, 'level1', 'level2', 'level3', 'level4', 'level5');

    if (reposDepth2.includes(level5Path)) {
      throw new Error('Max depth limit not respected');
    }

    console.log('✓ scanForRepositories passed');
  } finally {
    cleanup(testRoot);
  }
}

function testSkipDirectories() {
  console.log('Testing skip directories...');

  if (!SKIP_DIRS.has('node_modules')) throw new Error('node_modules should be in skip list');
  if (!SKIP_DIRS.has('.git')) throw new Error('.git should be in skip list');
  if (!SKIP_DIRS.has('dist')) throw new Error('dist should be in skip list');

  console.log('✓ Skip directories configured correctly');
}

function testExpandPath() {
  console.log('Testing expandPath...');

  const home = expandPath('~');
  if (home !== os.homedir()) {
    throw new Error(`Expected homedir, got ${home}`);
  }

  const local = expandPath('%LOCALAPPDATA%\\Programs\\cursor\\Cursor.exe');
  if (!local.toLowerCase().includes('appdata\\local\\programs\\cursor\\cursor.exe')) {
    throw new Error(`LOCALAPPDATA expansion failed: ${local}`);
  }

  console.log('✓ expandPath passed');
}

async function testScanDetectorsReturnsAllItems() {
  console.log('Testing scanDetectors returns full catalog...');

  const items = await scanDetectors([], os.homedir(), []);
  const catalog = loadDetectors();

  if (items.length < catalog.length) {
    throw new Error(`Expected at least ${catalog.length} catalog items, got ${items.length}`);
  }

  const cursor = items.find(i => i.id === 'cursor');
  if (!cursor) throw new Error('Cursor should be in catalog');
  if (!['unchecked', 'not-installed'].includes(cursor.status)) {
    throw new Error(`Unexpected cursor status: ${cursor.status}`);
  }

  const chatgpt = items.find(i => i.id === 'chatgpt');
  if (!chatgpt) throw new Error('ChatGPT should be in catalog even if not installed');

  console.log('✓ scanDetectors full catalog passed');
}

async function testDetectAppByPath() {
  console.log('Testing detectOne path detection...');

  const testRoot = path.join(os.tmpdir(), 'daily-update-detector-' + Date.now());
  const exePath = path.join(testRoot, 'FakeApp', 'FakeApp.exe');

  try {
    fs.mkdirSync(path.dirname(exePath), { recursive: true });
    fs.writeFileSync(exePath, '');

    const result = await detectOne({
      id: 'fake-app',
      name: 'Fake App',
      category: 'app',
      detect: { type: 'app', paths: [exePath] }
    }, []);

    if (!result.installed) throw new Error('Expected fake app to be detected');
    if (result.installPath !== exePath) {
      throw new Error(`Expected installPath ${exePath}, got ${result.installPath}`);
    }

    const missing = await detectOne({
      id: 'missing',
      name: 'Missing',
      category: 'app',
      detect: { type: 'app', paths: [path.join(testRoot, 'Nope', 'Nope.exe')] }
    }, []);

    if (missing.installed) throw new Error('Missing app should not be detected');

    console.log('✓ detectOne path detection passed');
  } finally {
    cleanup(testRoot);
  }
}

function testDetectorsCatalog() {
  console.log('Testing detectors catalog...');

  const items = loadDetectors();
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error('detectors.json should contain items');
  }

  const required = ['cursor', 'claude-app', 'chatgpt', 'antigravity', 'hermes', 'openclaw', 'codex-cli', 'claude-code'];
  for (const id of required) {
    if (!items.find(i => i.id === id)) throw new Error(`Missing detector: ${id}`);
  }

  const apps = items.filter(i => i.category === 'app');
  if (apps.length < 8) {
    throw new Error(`Expected at least 8 app detectors, found ${apps.length}`);
  }

  console.log('✓ detectors catalog passed');
}

async function runTests() {
  console.log('Running scanner tests...\n');

  try {
    testIsValidDirectory();
    testScanForRepositories();
    testSkipDirectories();
    testExpandPath();
    testDetectorsCatalog();
    await testScanDetectorsReturnsAllItems();
    await testDetectAppByPath();

    console.log('\n✓ All tests passed!');
    process.exit(0);
  } catch (err) {
    console.error('\n✗ Test failed:', err.message);
    console.error(err.stack);
    process.exit(1);
  }
}

runTests();
