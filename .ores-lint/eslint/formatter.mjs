/**
 * ores-lint :: capped ESLint formatter
 *
 * Same reporting contract as the Rust side: one block per rule, at most
 * ORES_LINT_MAX_EXAMPLES concrete locations, then a count of the remainder.
 */

const MAX = Math.max(1, Number(process.env.ORES_LINT_MAX_EXAMPLES || 5));

const LABELS = {
  semi: 'missing semicolon (ores house style)',
  'ores/semi': 'missing semicolon (ores house style)',
  'ores/require-send': 'logging chain never delivered (ores custom rule)',
};

export default function oresFormatter(results) {
  const byRule = new Map();
  let files = 0;
  let errors = 0;
  let warnings = 0;
  const parseErrors = [];

  for (const result of results) {
    if (!result.messages.length) continue;
    files++;
    const rel = (result.filePath || '').replace(`${process.cwd()}/`, '');
    for (const message of result.messages) {
      if (message.severity === 2) errors++; else warnings++;
      if (!message.ruleId) {
        parseErrors.push(`${rel}:${message.line || 0}: ${message.message}`);
        continue;
      }
      let entry = byRule.get(message.ruleId);
      if (!entry) {
        entry = { count: 0, examples: [], severity: message.severity, message: message.message };
        byRule.set(message.ruleId, entry);
      }
      entry.count++;
      if (entry.examples.length < MAX) {
        entry.examples.push(`${rel}:${message.line}:${message.column}`);
      }
    }
  }

  const examined = results.length;
  if (!byRule.size && !parseErrors.length) {
    return examined === 0
      ? 'ores-lint[js]: no lintable files matched (check ignores / file extensions)\n'
      : `ores-lint[js]: clean (${examined} file${examined === 1 ? '' : 's'} linted)\n`;
  }

  const out = [];
  const total = errors + warnings;
  out.push(`ores-lint[js]: ${total} finding(s) across ${byRule.size} rule(s) in ${files} of ${examined} file(s) linted`);

  const ordered = [...byRule.entries()].sort((left, right) => {
    const leftHouse = left[0] in LABELS ? 0 : 1;
    const rightHouse = right[0] in LABELS ? 0 : 1;
    return leftHouse - rightHouse || right[1].count - left[1].count;
  });

  for (const [ruleId, entry] of ordered) {
    const severity = entry.severity === 2 ? 'error' : 'warning';
    const label = LABELS[ruleId] || entry.message;
    out.push('');
    out.push(`  ${severity}: ${label}  [${ruleId}]`);
    out.push(`    ${entry.count} instance(s); showing ${Math.min(entry.count, MAX)}:`);
    for (const example of entry.examples) out.push(`      ${example}`);
    if (entry.count > MAX) out.push(`      ... and ${entry.count - MAX} more`);
  }

  if (parseErrors.length) {
    out.push('');
    out.push(`  note: ${parseErrors.length} file(s) could not be parsed (usually a missing parser, not a defect):`);
    for (const error of parseErrors.slice(0, MAX)) out.push(`      ${error}`);
    if (parseErrors.length > MAX) out.push(`      ... and ${parseErrors.length - MAX} more`);
  }

  out.push('');
  return `${out.join('\n')}\n`;
}
