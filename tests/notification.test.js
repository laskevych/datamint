const test = require('node:test');
const assert = require('node:assert');
const { sendChatNotification } = require('../src/index');

test('sendChatNotification is a no-op when CHAT_WEBHOOK_URL is not set', async () => {
  const originalUrl = process.env.CHAT_WEBHOOK_URL;
  delete process.env.CHAT_WEBHOOK_URL;

  const originalWarn = console.warn;
  let warned = false;
  console.warn = () => { warned = true; };

  try {
    await assert.doesNotReject(() => sendChatNotification('boom'));
    assert.strictEqual(warned, true, 'expected console.warn to be called');
  } finally {
    console.warn = originalWarn;
    if (originalUrl !== undefined) process.env.CHAT_WEBHOOK_URL = originalUrl;
  }
});
