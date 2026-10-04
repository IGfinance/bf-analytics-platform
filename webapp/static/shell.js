(function () {
  var navToggle = document.querySelector('[data-mobile-nav-toggle]');
  var nav = document.querySelector('[data-mobile-nav]');
  if (navToggle && nav) {
    navToggle.addEventListener('click', function () {
      nav.classList.toggle('hidden');
    });
  }

  // ---------- Выпадающий список (partials/ui.html: ui_select) ----------
  var selects = document.querySelectorAll('[data-ui-select]');

  function closeAll(except) {
    selects.forEach(function (root) {
      if (root === except) return;
      var list = root.querySelector('.ui-select__list');
      var btn = root.querySelector('.ui-select__button');
      if (list && !list.hidden) { list.hidden = true; btn.setAttribute('aria-expanded', 'false'); }
    });
  }

  function options(root) { return Array.prototype.slice.call(root.querySelectorAll('.ui-select__option')); }

  function openList(root) {
    closeAll(root);
    var list = root.querySelector('.ui-select__list');
    var btn = root.querySelector('.ui-select__button');
    list.hidden = false;
    btn.setAttribute('aria-expanded', 'true');
    var sel = list.querySelector('[aria-selected="true"]') || options(root)[0];
    if (sel) sel.focus();
  }

  function closeList(root, focusButton) {
    var list = root.querySelector('.ui-select__list');
    var btn = root.querySelector('.ui-select__button');
    list.hidden = true;
    btn.setAttribute('aria-expanded', 'false');
    if (focusButton) btn.focus();
  }

  function choose(root, opt) {
    var href = opt.getAttribute('data-href');
    if (href) { window.location = href; return; }     // опция-ссылка (переключатель проекта)
    options(root).forEach(function (o) { o.setAttribute('aria-selected', o === opt ? 'true' : 'false'); });
    var valueEl = root.querySelector('[data-ui-select-value]');
    valueEl.textContent = opt.querySelector('span').textContent;
    valueEl.classList.remove('ui-select__value--placeholder');
    var input = root.querySelector('[data-ui-select-input]');
    if (input) input.value = opt.getAttribute('data-value');
    closeList(root, true);
    root.dispatchEvent(new CustomEvent('ui-select-change', {
      bubbles: true,
      detail: { value: opt.getAttribute('data-value'), meta: opt.getAttribute('data-meta') || '' }
    }));
  }

  selects.forEach(function (root) {
    var btn = root.querySelector('.ui-select__button');
    var list = root.querySelector('.ui-select__list');
    btn.addEventListener('click', function () { list.hidden ? openList(root) : closeList(root, false); });
    btn.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); openList(root); }
    });
    list.addEventListener('click', function (e) {
      var opt = e.target.closest('.ui-select__option');
      if (opt) choose(root, opt);
    });
    list.addEventListener('keydown', function (e) {
      var opts = options(root);
      var i = opts.indexOf(document.activeElement);
      if (e.key === 'ArrowDown') { e.preventDefault(); opts[Math.min(i + 1, opts.length - 1)].focus(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); opts[Math.max(i - 1, 0)].focus(); }
      else if (e.key === 'Home') { e.preventDefault(); opts[0].focus(); }
      else if (e.key === 'End') { e.preventDefault(); opts[opts.length - 1].focus(); }
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (i >= 0) choose(root, opts[i]); }
      else if (e.key === 'Escape' || e.key === 'Tab') { closeList(root, e.key === 'Escape'); }
    });
  });

  document.addEventListener('click', function (e) {
    var inside = e.target.closest('[data-ui-select]');
    closeAll(inside);
  });

  // ---------- «Загрузка»: кабинет включает/выключает двери по площадкам ----------
  // Кнопки дверей НЕ блокируются: заблокированная кнопка молча «ничего не делала» — пользователь не
  // понимал, что не выбран кабинет (в пятницу 2026-10-02 запрос на сервер даже не уходил). Вместо
  // блокировки при отправке показывается сообщение (data-door-message), форма не уходит.
  var cabinetSelect = document.querySelector('[data-cabinet-select]');
  var currentCabinet = { value: '', platforms: [] };
  var PLATFORM_NAMES = { wb: 'WB', ozon: 'Ozon' };

  function showDoorMessage(door, text) {
    var m = door.querySelector('[data-door-message]');
    if (!m) return;
    m.textContent = text || '';
    m.hidden = !text;
  }

  // Сообщение, почему форму двери нельзя отправить; '' — можно.
  function doorBlockMessage(door) {
    var platform = door.getAttribute('data-platform');
    if (platform) {
      // Кабинет не выбран — не блокируем: сервер определит его по файлу, а если не сможет, вернёт
      // понятную просьбу выбрать вручную (upload_checks/detect.py).
      if (currentCabinet.value && currentCabinet.platforms.indexOf(platform) === -1) {
        return 'У кабинета «' + currentCabinet.value + '» нет площадки ' + PLATFORM_NAMES[platform] + '.';
      }
    }
    var input = door.querySelector('[data-door-file]');
    var accept = input && input.getAttribute('accept');
    if (input && accept && input.files && input.files.length) {
      var exts = accept.split(',').map(function (x) { return x.trim().toLowerCase(); });
      for (var i = 0; i < input.files.length; i++) {
        var name = String(input.files[i].name || '');
        var lower = name.toLowerCase();
        var good = exts.some(function (x) { return lower.slice(-x.length) === x; });
        if (!good) return 'Для этой загрузки нужны файлы ' + accept + '. Выбран другой тип: «' + name + '».';
      }
    }
    return '';
  }

  // Подсказка под кнопкой двери: «Кабинет определён…» (зелёная) или «не удалось…» (серая).
  function setDetectNote(door, text, ok) {
    var n = door.querySelector('[data-door-detect]');
    if (!n) return;
    n.textContent = text || '';
    n.hidden = !text;
    n.classList.toggle('text-success-text', !!ok);
    n.classList.toggle('text-secondary', !ok);
  }

  // Выбирает кабинет в переключателе так, как будто его выбрал пользователь (сработают двери, зеркало).
  function selectCabinetOption(value) {
    if (!cabinetSelect) return false;
    var opts = cabinetSelect.querySelectorAll('.ui-select__option');
    for (var i = 0; i < opts.length; i++) {
      if (opts[i].getAttribute('data-value') === value) {
        if (opts[i].getAttribute('aria-selected') !== 'true') opts[i].click();
        return true;
      }
    }
    return false;
  }

  // Прикрепили файл → сервер определяет кабинет по его содержимому (номер отчёта WB / SKU Ozon).
  // Ничего не пишет в базу. Сбой сети — молча: загрузка всё равно определит кабинет сама.
  function detectCabinetFor(door, input) {
    var url = door.getAttribute('data-detect-url');
    setDetectNote(door, '');
    if (!url || typeof fetch !== 'function' || typeof FormData === 'undefined' || !input.files || !input.files.length) return;
    var fd = new FormData();
    for (var i = 0; i < input.files.length; i++) fd.append(input.getAttribute('name') || 'files', input.files[i]);
    setDetectNote(door, 'Определяю кабинет по файлу…');
    fetch(url, { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (res) {
        if (res && res.cabinet && selectCabinetOption(res.cabinet)) {
          setDetectNote(door, 'Кабинет определён: «' + res.cabinet + '» — ' + res.message + '.', true);
        } else if (res && res.cabinet) {
          setDetectNote(door, 'Файл относится к кабинету «' + res.cabinet + '», которого нет в списке — выберите кабинет вручную.');
        } else {
          setDetectNote(door, ((res && res.message) || 'Кабинет по файлу определить не удалось.') + ' Выберите его справа вверху страницы.');
        }
      })
      .catch(function () { setDetectNote(door, ''); });
  }

  document.querySelectorAll('[data-door]').forEach(function (door) {
    var form = door.querySelector('[data-door-form]');
    if (!form) return;
    form.addEventListener('submit', function (e) {
      var msg = doorBlockMessage(door);
      showDoorMessage(door, msg);
      if (msg) {
        e.preventDefault();
      }
    });
    var fileInput = door.querySelector('[data-door-file]');
    if (fileInput) fileInput.addEventListener('change', function () {
      showDoorMessage(door, '');
      var msg = doorBlockMessage(door);
      if (msg) { showDoorMessage(door, msg); setDetectNote(door, ''); return; }   // не тот тип файла — сразу скажем
      detectCabinetFor(door, fileInput);
    });
  });

  if (cabinetSelect) {
    var mirrors = document.querySelectorAll('[data-cabinet-mirror]');
    var doors = document.querySelectorAll('[data-door][data-platform]');

    var applyCabinet = function (value, meta) {
      var platforms = meta ? meta.split(',') : [];
      currentCabinet = { value: value, platforms: platforms };
      cabinetSelect.classList.remove('ui-select--attention');
      mirrors.forEach(function (m) { m.value = value; });
      doors.forEach(function (door) {
        var ok = !!value && platforms.indexOf(door.getAttribute('data-platform')) !== -1;
        var hint = door.querySelector('[data-cabinet-hint]');
        door.classList.toggle('door-unavailable', !!value && !ok);
        showDoorMessage(door, '');
        if (hint) {
          hint.textContent = !value ? 'Кабинет определится по файлу сам; если не получится — выберите его справа вверху страницы.'
            : ok ? '' : 'У кабинета «' + value + '» нет площадки ' + PLATFORM_NAMES[door.getAttribute('data-platform')] + '.';
        }
      });
    };

    cabinetSelect.addEventListener('ui-select-change', function (e) { applyCabinet(e.detail.value, e.detail.meta); });
    var preset = cabinetSelect.querySelector('[aria-selected="true"]');
    if (preset) applyCabinet(preset.getAttribute('data-value'), preset.getAttribute('data-meta') || '');
  }
})();
