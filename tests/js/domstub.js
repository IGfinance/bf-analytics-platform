// Заглушка DOM для проверки логики webapp/static/shell.js без браузера (JavaScriptCore, macOS).
// Запуск: tests/test_shell_js.py (pytest), либо вручную — см. там.
var global = this;
// Минимальная заглушка DOM для проверки логики shell.js (выбор кабинета → двери)
function El(tag, attrs){ this.tag=tag; this.attrs=attrs||{}; this.children=[]; this.listeners={}; this.hidden=false; this.value=''; this.textContent=''; this.disabled=false; this._cls={};
  var self=this; this.classList={add:function(c){self._cls[c]=1},remove:function(c){delete self._cls[c]},toggle:function(c,f){ if(f===undefined) f=!self._cls[c]; if(f) self._cls[c]=1; else delete self._cls[c]; }, contains:function(c){return !!self._cls[c]}}; }
El.prototype.getAttribute=function(k){return this.attrs[k]===undefined?null:this.attrs[k]};
El.prototype.setAttribute=function(k,v){this.attrs[k]=String(v)};
El.prototype.addEventListener=function(t,f){(this.listeners[t]=this.listeners[t]||[]).push(f)};
El.prototype.dispatchEvent=function(e){(this.listeners[e.type]||[]).forEach(function(f){f(e)}); return true};
El.prototype.focus=function(){ global.activeElement=this };
El.prototype.querySelector=function(sel){ return this._q(sel)[0]||null };
El.prototype.querySelectorAll=function(sel){ return this._q(sel) };
El.prototype.closest=function(){return this.__closest||null};
El.prototype._q=function(sel){ var out=[]; (function walk(n){ n.children.forEach(function(c){ if(c._m(sel)) out.push(c); walk(c); }); })(this); return out; };
El.prototype._m=function(sel){ var s=sel.trim();
  if(s.charAt(0)==='.') return !!this._cls[s.slice(1)] || (this.attrs['class']||'').split(' ').indexOf(s.slice(1))>-1;
  var m=s.match(/^\[([\w-]+)(?:="([^"]*)")?\]$/); if(m) return this.attrs[m[1]]!==undefined && (m[2]===undefined || this.attrs[m[1]]===m[2]);
  m=s.match(/^\[([\w-]+)\]\[([\w-]+)\]$/); if(m) return this.attrs[m[1]]!==undefined && this.attrs[m[2]]!==undefined;
  return false; };
function CustomEvent(type,init){ this.type=type; this.detail=init&&init.detail; }
