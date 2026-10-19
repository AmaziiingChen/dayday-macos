const hostName = "app.dayday.browser_bridge";
let port;
let sequence = 0;

function connect() {
  if (port) return port;
  port = chrome.runtime.connectNative(hostName);
  port.onDisconnect.addListener(() => {
    port = undefined;
  });
  return port;
}

async function publishSafetyState() {
  let window;
  try {
    window = await chrome.windows.getLastFocused({populate: true});
  } catch (_) {
    return;
  }
  const tab = window.tabs?.find((candidate) => candidate.active);
  const incognito = Boolean(window.incognito || tab?.incognito);
  connect().postMessage({
    protocolVersion: 1,
    sequence: ++sequence,
    bridgeReady: true,
    incognito
  });
}

chrome.runtime.onInstalled.addListener(publishSafetyState);
chrome.runtime.onStartup.addListener(publishSafetyState);
chrome.windows.onFocusChanged.addListener(publishSafetyState);
chrome.tabs.onActivated.addListener(publishSafetyState);
chrome.tabs.onUpdated.addListener((_tabId, changeInfo) => {
  if (changeInfo.status || changeInfo.url || changeInfo.audible || changeInfo.mutedInfo) {
    publishSafetyState();
  }
});
chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0) publishSafetyState();
});
chrome.alarms.create("dayday-heartbeat", {periodInMinutes: 0.5});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "dayday-heartbeat") publishSafetyState();
});
publishSafetyState();
