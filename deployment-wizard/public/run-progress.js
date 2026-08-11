'use strict';

/*
 * Live progress rendering for a bootstrap.sh / upgrade.sh / settings run.
 *
 * Previously this ~95-line block was copy-pasted into 06-deploy.ejs,
 * upgrade-progress.ejs and settings-progress.ejs. It lives here so the
 * failure-handling and screen-reader behaviour can't drift between the three
 * pages that all consume the same /api/deploy/stream events.
 *
 * initRunProgress({
 *   runId,          required — the run to subscribe to
 *   successText,    banner headline on exit code 0
 *   failText,       banner headline on any other exit code
 *   backHref,       where "Back" goes on failure
 *   backLabel,      its label
 *   retryRedirect,  page to land on after a successful retry (runId appended)
 *   stepHints,      optional { '<step key>': 'extra note while running' }
 *   onSuccess       optional callback
 * })
 */
function initRunProgress(opts) {
  var stepsList = document.getElementById('deploySteps');
  var overallStatus = document.getElementById('overallStatus');
  var rawLog = document.getElementById('rawLog');
  var actionsBox = document.getElementById('runActions');
  var stepHints = opts.stepHints || {};

  var stepRows = new Map();
  var activeStepKey = null;

  function badgeFor(status) {
    return {
      pending: '<span class="badge badge-pending">…</span>',
      running: '<span class="badge badge-warn">RUNNING</span>',
      done: '<span class="badge badge-ok">DONE</span>',
      failed: '<span class="badge badge-fail">FAILED</span>'
    }[status] || '<span class="badge badge-pending">…</span>';
  }

  function render(li) {
    var hint = (li.dataset.status === 'running' && stepHints[li.dataset.key])
      ? ' <span class="hint" style="display:inline;">(' + escapeHtml(stepHints[li.dataset.key]) + ')</span>'
      : '';
    li.innerHTML = badgeFor(li.dataset.status) + '<span>' + escapeHtml(li.dataset.label || '') + hint + '</span>';
  }

  function upsertStep(key, label) {
    var li = stepRows.get(key);
    if (!li) {
      li = document.createElement('li');
      li.dataset.status = 'pending';
      li.dataset.key = key;
      stepsList.appendChild(li);
      stepRows.set(key, li);
    }
    li.dataset.label = label;
    render(li);
    return li;
  }

  function setStatus(li, status) {
    li.dataset.status = status;
    render(li);
  }

  function appendSubCheck(status, label) {
    var cls = status === 'ok' ? 'badge-ok' : status === 'fail' ? 'badge-fail' : 'badge-warn';
    var li = document.createElement('li');
    li.innerHTML = '<span class="badge ' + cls + '">' + escapeHtml(String(status).toUpperCase())
      + '</span><span>' + escapeHtml(label) + '</span>';
    stepsList.appendChild(li);
  }

  function button(label, cls, onClick) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn ' + cls;
    b.textContent = label;
    b.addEventListener('click', onClick);
    return b;
  }

  function showOutcome(success, exitCode) {
    // Written into the existing role="status" element rather than replacing
    // it — swapping the node out would drop the live region and the outcome
    // would never be announced.
    overallStatus.className = 'run-outcome ' + (success ? 'run-outcome-success' : 'run-outcome-failure');
    overallStatus.innerHTML = success
      ? '<span><strong>' + escapeHtml(opts.successText) + '</strong></span>'
      : '<span><strong>' + escapeHtml(opts.failText) + '</strong>'
        + '<span class="run-outcome-detail">Exit code ' + escapeHtml(String(exitCode))
        + '. Expand <em>Raw output</em> above for the full log, or copy it below to share.</span></span>';

    if (success) {
      if (opts.onSuccess) opts.onSuccess();
      return;
    }

    // Failure: give the operator somewhere to go. Nothing here used to exist.
    actionsBox.hidden = false;

    var errorLine = document.createElement('p');
    errorLine.className = 'error-text';
    errorLine.style.margin = '0';

    var retryBtn = button('Retry', 'btn-primary', function () {
      retryBtn.disabled = true;
      retryBtn.textContent = 'Starting…';
      fetch('/api/deploy/retry', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ runId: opts.runId })
      })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) throw new Error(res.d.error || 'Could not start the retry.');
          window.location.href = opts.retryRedirect + '?runId=' + encodeURIComponent(res.d.runId);
        })
        .catch(function (err) {
          retryBtn.disabled = false;
          retryBtn.textContent = 'Retry';
          errorLine.textContent = err.message;
        });
    });

    var copyBtn = button('Copy log', 'btn-secondary', function () {
      copyText(rawLog.textContent, function (ok) {
        copyBtn.textContent = ok ? 'Copied' : 'Press Ctrl+C';
        setTimeout(function () { copyBtn.textContent = 'Copy log'; }, 2500);
      });
    });

    var back = document.createElement('a');
    back.href = opts.backHref;
    back.className = 'btn btn-secondary';
    back.textContent = opts.backLabel;

    actionsBox.appendChild(retryBtn);
    actionsBox.appendChild(back);
    actionsBox.appendChild(copyBtn);
    actionsBox.appendChild(errorLine);
    retryBtn.focus();
  }

  var source = new EventSource('/api/deploy/stream?runId=' + encodeURIComponent(opts.runId));

  source.addEventListener('step', function (e) {
    var data = JSON.parse(e.data);
    if (activeStepKey && stepRows.has(activeStepKey)) setStatus(stepRows.get(activeStepKey), 'done');
    setStatus(upsertStep(data.step, data.label), 'running');
    activeStepKey = data.step;
  });

  source.addEventListener('check', function (e) {
    var data = JSON.parse(e.data);
    appendSubCheck(data.status, data.label);
  });

  source.addEventListener('warning', function (e) {
    appendSubCheck('warn', JSON.parse(e.data).message);
  });

  source.addEventListener('error', function (e) {
    // EventSource fires a bare transport-level 'error' with no payload when
    // the connection drops; only the server's own error events carry data.
    if (!e.data) return;
    appendSubCheck('fail', JSON.parse(e.data).message);
  });

  source.addEventListener('log', function (e) {
    rawLog.textContent += JSON.parse(e.data).line + '\n';
    rawLog.scrollTop = rawLog.scrollHeight;
  });

  source.addEventListener('done', function (e) {
    var data = JSON.parse(e.data);
    if (activeStepKey && stepRows.has(activeStepKey)) {
      setStatus(stepRows.get(activeStepKey), data.success ? 'done' : 'failed');
    }
    showOutcome(data.success, data.exitCode);
    source.close();
    unlockTopbarNav();
  });
}
