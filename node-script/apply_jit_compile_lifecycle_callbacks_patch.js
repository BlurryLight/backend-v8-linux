const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const v8Path = path.resolve(process.argv[2]);
const v8Version = process.argv[3];
const workspace = path.resolve(__dirname, '..');
const patchFile = path.join(
  workspace,
  'patches',
  'jit_compile_lifecycle_callbacks_v11.8.172.patch'
);
const applyPatchScript = path.join(workspace, 'node-script', 'do-gitpatch.js');

function patchAlreadyApplied() {
  const isolateHeader = fs.readFileSync(
    path.join(v8Path, 'include', 'v8-isolate.h'),
    'utf-8'
  );
  const callbacksHeader = fs.readFileSync(
    path.join(v8Path, 'include', 'v8-callbacks.h'),
    'utf-8'
  );
  return (
    isolateHeader.includes('AddJitCodeEventPrologueCallback') &&
    isolateHeader.includes('AddJitCodeEventEpilogueCallback') &&
    callbacksHeader.includes('enum JitCodeEventKind {')
  );
}

function main() {
  if (v8Version !== '11.8.172') {
    console.log(`skip jit compile lifecycle patch for version ${v8Version}`);
    return;
  }

  if (patchAlreadyApplied()) {
    console.log('jit compile lifecycle patch already applied, skipping.');
    return;
  }

  console.log('=====[ patch jit compile lifecycle callbacks ]=====');
  execFileSync('node', [applyPatchScript, '-p', patchFile], {
    cwd: v8Path,
    stdio: 'inherit',
  });
}

main();
