// Proves the token lint rule works (UI_STANDARD §3): Stylelint must refuse every declaration in lint-fixtures/forbidden.css.
import stylelint from 'stylelint';

const result = await stylelint.lint({ files: 'lint-fixtures/forbidden.css', configFile: '.stylelintrc.json' });
const warnings = result.results.flatMap((r) => r.warnings);
const rules = new Set(warnings.map((w) => w.rule));
const expected = ['color-no-hex', 'function-disallowed-list', 'declaration-property-unit-disallowed-list', 'property-disallowed-list'];
const missing = expected.filter((r) => !rules.has(r));
if (missing.length) {
  console.error(`Lint self-test failed: these rules did not fire: ${missing.join(', ')}`);
  process.exit(1);
}
console.log(`Lint self-test passed: ${warnings.length} forbidden declarations refused (${[...rules].join(', ')}).`);
