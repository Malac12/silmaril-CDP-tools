const transcriptEl = document.getElementById('transcript');
const activityEl = document.getElementById('activity');
const chromeStatusEl = document.getElementById('chrome-status');
const sessionStatusEl = document.getElementById('session-status');
const promptInputEl = document.getElementById('prompt-input');
const sendButtonEl = document.getElementById('send-button');
const cancelButtonEl = document.getElementById('cancel-button');
const restartButtonEl = document.getElementById('restart-button');
const approvalToggleEl = document.getElementById('approval-toggle');
const approvalModeLabelEl = document.getElementById('approval-mode-label');
const approvalModeHintEl = document.getElementById('approval-mode-hint');
const approvalCardEl = document.getElementById('pending-approval');
const approvalSummaryEl = document.getElementById('approval-summary');
const approvalCommandEl = document.getElementById('approval-command');
const approvalReasonEl = document.getElementById('approval-reason');
const approveButtonEl = document.getElementById('approve-button');
const rejectButtonEl = document.getElementById('reject-button');

let appState = {
  chromeState: null,
  sessionState: null,
  settings: null,
  pendingApproval: null
};

function scrollToBottom(element) {
  element.scrollTop = element.scrollHeight;
}

function formatTime(timestamp) {
  const date = new Date(timestamp);
  return date.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit'
  });
}

function renderTranscriptEntry(entry) {
  const item = document.createElement('article');
  item.className = `message ${entry.role}`;
  item.innerHTML = `
    <div class="message-meta">
      <span>${entry.role === 'assistant' ? 'Codex' : 'You'}</span>
      <span>${formatTime(entry.timestamp)}</span>
    </div>
    <div class="message-body"></div>
  `;
  item.querySelector('.message-body').textContent = entry.text || '';
  transcriptEl.appendChild(item);
  scrollToBottom(transcriptEl);
}

function renderActivityEntry(entry) {
  const item = document.createElement('article');
  item.className = `activity-entry ${entry.level || 'info'}`;
  item.innerHTML = `
    <div class="activity-meta">
      <strong>${entry.label}</strong>
      <span>${formatTime(entry.timestamp)}</span>
    </div>
    <pre class="activity-detail"></pre>
  `;
  item.querySelector('.activity-detail').textContent = entry.detail || '';
  activityEl.appendChild(item);
  scrollToBottom(activityEl);
}

function renderStatus() {
  const chromeState = appState.chromeState;
  const sessionState = appState.sessionState;

  if (chromeState && chromeState.connected) {
    chromeStatusEl.textContent = `Chrome ${chromeState.port} connected`;
    chromeStatusEl.className = 'status-pill success';
  }
  else {
    chromeStatusEl.textContent = chromeState && chromeState.lastError
      ? `Chrome offline: ${chromeState.lastError}`
      : 'Chrome offline';
    chromeStatusEl.className = 'status-pill error';
  }

  if (!sessionState) {
    sessionStatusEl.textContent = 'Codex unavailable';
    sessionStatusEl.className = 'status-pill muted';
    return;
  }

  if (sessionState.runState === 'running') {
    sessionStatusEl.textContent = 'Codex busy';
    sessionStatusEl.className = 'status-pill warning';
  }
  else if (sessionState.runState === 'error') {
    sessionStatusEl.textContent = 'Codex error';
    sessionStatusEl.className = 'status-pill error';
  }
  else if (sessionState.threadId) {
    sessionStatusEl.textContent = 'Codex session active';
    sessionStatusEl.className = 'status-pill success';
  }
  else {
    sessionStatusEl.textContent = 'Codex idle';
    sessionStatusEl.className = 'status-pill muted';
  }
}

function renderPendingApproval() {
  const approval = appState.pendingApproval;
  if (!approval) {
    approvalCardEl.classList.add('hidden');
    approvalSummaryEl.textContent = '';
    approvalCommandEl.textContent = '';
    approvalReasonEl.textContent = '';
    return;
  }

  approvalCardEl.classList.remove('hidden');
  approvalSummaryEl.textContent = approval.summary || 'Mutation requires confirmation';
  approvalCommandEl.textContent = approval.command || approval.raw || '';
  approvalReasonEl.textContent = approval.reason || '';
}

function renderApprovalMode() {
  const approvalMode = appState.settings && appState.settings.approvalMode === 'auto'
    ? 'auto'
    : 'confirm_mutations';

  if (approvalMode === 'auto') {
    approvalModeLabelEl.textContent = 'Auto approve';
    approvalModeHintEl.textContent = 'Run browser actions without prompting';
    approvalToggleEl.checked = false;
    approvalToggleEl.setAttribute('aria-label', 'Auto approve browser actions');
    return;
  }

  approvalModeLabelEl.textContent = 'Ask first';
  approvalModeHintEl.textContent = 'Prompt before browser actions';
  approvalToggleEl.checked = true;
  approvalToggleEl.setAttribute('aria-label', 'Ask before browser actions');
}

async function handleSend() {
  const prompt = promptInputEl.value.trim();
  if (!prompt) {
    return;
  }

  try {
    sendButtonEl.disabled = true;
    const result = await window.bridgeApi.sendPrompt(prompt);
    if (!result.ok) {
      renderActivityEntry({
        timestamp: Date.now(),
        level: 'error',
        label: 'Prompt rejected',
        detail: result.error
      });
      return;
    }

    promptInputEl.value = '';
  }
  catch (error) {
    renderActivityEntry({
      timestamp: Date.now(),
      level: 'error',
      label: 'Prompt failed',
      detail: error && error.message ? error.message : String(error)
    });
  }
  finally {
    sendButtonEl.disabled = false;
  }
}

async function bootstrap() {
  const snapshot = await window.bridgeApi.getSnapshot();
  appState = snapshot;

  transcriptEl.innerHTML = '';
  activityEl.innerHTML = '';

  snapshot.transcriptEntries.forEach(renderTranscriptEntry);
  snapshot.activityEntries.forEach(renderActivityEntry);
  renderPendingApproval();
  renderApprovalMode();
  renderStatus();
}

sendButtonEl.addEventListener('click', handleSend);
promptInputEl.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
    event.preventDefault();
    handleSend();
  }
});

cancelButtonEl.addEventListener('click', async () => {
  await window.bridgeApi.cancel();
});

restartButtonEl.addEventListener('click', async () => {
  await window.bridgeApi.restart();
});

approvalToggleEl.addEventListener('change', async () => {
  const approvalMode = approvalToggleEl.checked ? 'confirm_mutations' : 'auto';
  appState.settings = await window.bridgeApi.updateSettings({ approvalMode });
  renderApprovalMode();
});

approveButtonEl.addEventListener('click', async () => {
  await window.bridgeApi.approvePending();
});

rejectButtonEl.addEventListener('click', async () => {
  await window.bridgeApi.rejectPending();
});

window.bridgeApi.onTranscript((entry) => {
  renderTranscriptEntry(entry);
});

window.bridgeApi.onActivity((entry) => {
  renderActivityEntry(entry);
});

window.bridgeApi.onChromeState((chromeState) => {
  appState.chromeState = chromeState;
  renderStatus();
});

window.bridgeApi.onSessionState((sessionState) => {
  appState.sessionState = sessionState;
  renderStatus();
});

window.bridgeApi.onPendingApproval((approval) => {
  appState.pendingApproval = approval;
  renderPendingApproval();
});

window.bridgeApi.onSettings((settings) => {
  appState.settings = settings;
  renderApprovalMode();
});

bootstrap().catch((error) => {
  renderActivityEntry({
    timestamp: Date.now(),
    level: 'error',
    label: 'Bootstrap failed',
    detail: error.message
  });
});
