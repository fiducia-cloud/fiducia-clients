import {readFileSync, existsSync, readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {resolve, join, posix} from 'node:path';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const ORESLANG = /oreslang/i;
const IDENTITY_FIELD = /(?:^|[_-])(?:language|lang|runtime|target|renderer|package|root|directory|dir|path|sdk|module|backend|binding)(?:$|[_-])/i;

/**
 * Search actual SDK directories, not a hard-coded list of four names.
 * This does not follow symlinks, so a linked directory cannot recursively
 * escape the checkout. Symlink names themselves are still inspected.
 */
export function listSdkPaths(repositoryRoot) {
  const clients = resolve(repositoryRoot, 'clients');
  if (!existsSync(clients)) throw new Error('clients directory is missing');
  const paths = [];
  function visit(dir, relativePath, depth) {
    if (depth > 16) throw new Error('SDK tree exceeds admission scan depth');
    for (const entry of readdirSync(dir, {withFileTypes: true})) {
      // Any .ores source is an unadmitted compiler target, even when its
      // path is disguised as another SDK (e.g. clients/custom/bridge.ores).
      const sourceFile = entry.isFile() && /\.ores$/i.test(entry.name);
      if (!entry.isDirectory() && !entry.isSymbolicLink() && !sourceFile) continue;
      const local = relativePath ? posix.join(relativePath, entry.name) : entry.name;
      if (entry.isSymbolicLink()) throw new Error('SDK tree contains an uninspected symbolic link: ' + local);
      paths.push(posix.join('clients', local));
      if (paths.length > 25000) throw new Error('SDK tree exceeds admission scan size');
      if (entry.isDirectory()) visit(join(dir, entry.name), local, depth + 1);
    }
  }
  visit(clients, '', 0);
  return paths;
}

function identityValues(target, meta) {
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) {
    throw new Error('invalid client target metadata: ' + target);
  }
  const values = [target];
  const seen = new WeakSet();
  function visit(value, key, depth) {
    if (depth > 12) throw new Error('client target metadata nesting is excessive: ' + target);
    if (typeof value === 'string') {
      if (IDENTITY_FIELD.test(key)) values.push(value);
    } else if (value && typeof value === 'object') {
      if (seen.has(value)) throw new Error('cyclic client target metadata: ' + target);
      seen.add(value);
      for (const [childKey, child] of Object.entries(value)) visit(child, childKey, depth + 1);
      seen.delete(value);
    }
  }
  visit(meta, '', 0);
  return values;
}

/**
 * An unadmitted Oreslang SDK must not enter the target matrix, including via
 * nested language aliases, or appear in the actual clients tree.
 * Native compiler + TJSV runtime evidence is required to lift this gate.
 */
export function verifyStagedOreslang({matrix, presentPaths}) {
  if (!matrix || typeof matrix !== 'object' || Array.isArray(matrix)
      || !matrix.targets || typeof matrix.targets !== 'object'
      || Array.isArray(matrix.targets)) {
    throw new Error('invalid client target matrix');
  }
  if (!Array.isArray(presentPaths) || presentPaths.some(path => typeof path !== 'string')) {
    throw new Error('invalid client directory inventory');
  }
  for (const [target, meta] of Object.entries(matrix.targets)) {
    if (identityValues(target, meta).some(value => ORESLANG.test(value))) {
      throw new Error('Oreslang target is not runtime-admitted: ' + target);
    }
  }
  for (const path of presentPaths) {
    if (ORESLANG.test(path.replaceAll('\\', '/')) || /\.ores$/i.test(path)) {
      throw new Error('Oreslang SDK candidate directory lacks native admission: ' + path);
    }
  }
  return true;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const matrix = JSON.parse(readFileSync(resolve(root, 'clients/client-contract-matrix.json'), 'utf8'));
  verifyStagedOreslang({matrix, presentPaths: listSdkPaths(root)});
  console.log('Oreslang remains explicitly staged: no unsupported SDK/JS/Wasm targets admitted');
}
