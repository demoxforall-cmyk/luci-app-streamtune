// streamtune — проверка фронтенда: синтаксис JS-вью (как их парсит LuCI,
// с верхнеуровневым return внутри замыкания) + валидность JSON ACL/menu.
// Запуск: deno run --allow-read tests/check_js.mjs
const base = new URL('../luci-app-streamtune/', import.meta.url);
let fail = 0;
const ok  = (m) => console.log('  ok:   ' + m);
const bad = (m) => { console.log('  FAIL: ' + m); fail = 1; };

const JS = [
	'htdocs/luci-static/resources/streamtune.js',
	'htdocs/luci-static/resources/view/streamtune/overview.js',
	'htdocs/luci-static/resources/view/streamtune/diagnostics.js',
];
const JSON_FILES = [
	'root/usr/share/rpcd/acl.d/luci-app-streamtune.json',
	'root/usr/share/luci/menu.d/luci-app-streamtune.json',
];

console.log('== check_js ==');
for (const rel of JS) {
	const src = await Deno.readTextFile(new URL(rel, base));
	try { new Function(src); ok('js syntax: ' + rel.split('/').pop()); }
	catch (e) { bad('js syntax: ' + rel + ' -> ' + e.message); }
}
for (const rel of JSON_FILES) {
	const src = await Deno.readTextFile(new URL(rel, base));
	try { JSON.parse(src); ok('json valid: ' + rel.split('/').pop()); }
	catch (e) { bad('json invalid: ' + rel + ' -> ' + e.message); }
}

console.log(fail === 0 ? 'check_js: PASS' : 'check_js: FAIL');
Deno.exit(fail);
