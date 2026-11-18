// [layer: unit | Native Android source contract]
// A WebView renderer killed by Android must be explicitly handled. Leaving
// Capacitor's default false return value can leave the activity on a blank surface.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const source = readFileSync(
  new URL('../../android/app/src/main/java/com/example/deepseekchat/MainActivity.java', import.meta.url),
  'utf8'
)

test('recreates the Capacitor activity after its WebView renderer is killed', () => {
  assert.match(source, /getBridge\(\)\.addWebViewListener\(new WebViewListener\(\)/)
  assert.match(source, /boolean onRenderProcessGone\(WebView view, RenderProcessGoneDetail detail\)/)
  assert.match(source, /runOnUiThread\(MainActivity\.this::recreate\)/)
  assert.match(source, /return true;/)
})
