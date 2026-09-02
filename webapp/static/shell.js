(function () {
  var navToggle = document.querySelector('[data-mobile-nav-toggle]');
  var nav = document.querySelector('[data-mobile-nav]');
  if (navToggle && nav) {
    navToggle.addEventListener('click', function () {
      nav.classList.toggle('hidden');
    });
  }

  var projectSelect = document.querySelector('[data-project-select]');
  if (projectSelect) {
    projectSelect.addEventListener('change', function () {
      if (this.value) window.location = this.value;
    });
  }

  var cabinetShared = document.querySelector('[data-cabinet-shared]');
  var cabinetMirrors = document.querySelectorAll('[data-cabinet-mirror]');
  if (cabinetShared && cabinetMirrors.length) {
    var syncCabinet = function () {
      cabinetMirrors.forEach(function (m) { m.value = cabinetShared.value; });
    };
    cabinetShared.addEventListener('input', syncCabinet);
    syncCabinet();
  }
})();
