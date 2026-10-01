// Проверка логики shell.js: выпадающий список, выбор кабинета → двери по площадкам (ТЗ 04, блок C).
load(ARGS_DOMSTUB);
var assertCount=0; function ok(c,m){ assertCount++; if(!c){ print("FAIL: "+m); throw new Error(m);} }
// --- разметка: переключатель кабинета + три кабинетные двери + одна без площадки
var root=new El('div',{'data-ui-select':'','data-cabinet-select':''});
var btn=new El('button',{'class':'ui-select__button','aria-expanded':'false'});
var val=new El('span',{'data-ui-select-value':''}); val.classList=val.classList; btn.children.push(val);
var list=new El('ul',{'class':'ui-select__list'}); list.hidden=true;
function opt(v,meta,label){ var o=new El('li',{'class':'ui-select__option','data-value':v,'data-meta':meta,'aria-selected':'false'}); var sp=new El('span'); sp.textContent=label; o.children.push(sp); o.querySelector=function(s){return s==='span'?sp:null}; o.closest=function(){return o}; return o; }
var oArb=opt('ARB','wb','ARB'), oCs=opt('CloudSix','ozon,wb','CloudSix'), oIs=opt('Isonic','ozon','Isonic');
list.children.push(oArb,oCs,oIs); root.children.push(btn,list);
function door(platform){ var d=new El('div',{'data-door':'','data-platform':platform}); var b=new El('button',{'data-needs-cabinet':''}); b.disabled=true; var h=new El('p',{'data-cabinet-hint':''}); d.children.push(b,h); d.btn=b; d.hint=h; return d; }
var dWb=door('wb'), dOz=door('ozon'), mirror=new El('input',{'data-cabinet-mirror':''});
var all=[root,dWb,dOz,mirror];
global.document={ querySelector:function(s){ return this.querySelectorAll(s)[0]||null },
  querySelectorAll:function(s){ var out=[]; all.forEach(function(e){ if(e._m(s)) out.push(e); e._q(s).forEach(function(c){out.push(c)}); }); return out; },
  addEventListener:function(){} };
global.window={location:''};
var src=readFile(ARGS_SHELL); eval(src);
// начальное состояние: ничего не выбрано — кнопки disabled, подсказка есть
ok(dWb.btn.disabled && dOz.btn.disabled,'до выбора кабинета кнопки неактивны');
// выбираем ARB (только WB)
list.listeners.click[0]({target:oArb});
ok(mirror.value==='ARB','hidden-зеркало получило кабинет');
ok(val.textContent==='ARB','кнопка показывает выбранное');
ok(oArb.getAttribute('aria-selected')==='true' && oCs.getAttribute('aria-selected')==='false','aria-selected переключился');
ok(dWb.btn.disabled===false,'WB-дверь включена у WB-кабинета');
ok(dOz.btn.disabled===true && dOz.classList.contains('door-unavailable'),'Ozon-дверь выключена у WB-only кабинета');
ok(/нет площадки Ozon/.test(dOz.hint.textContent),'подсказка объясняет почему: '+dOz.hint.textContent);
// CloudSix — обе площадки
list.listeners.click[0]({target:oCs});
ok(!dWb.btn.disabled && !dOz.btn.disabled && !dOz.classList.contains('door-unavailable') && dOz.hint.textContent==='','обе двери включены у кабинета с двумя площадками');
// Isonic — только Ozon
list.listeners.click[0]({target:oIs});
ok(dWb.btn.disabled && !dOz.btn.disabled,'Isonic: WB выключена, Ozon включена');
// клавиатура: Escape закрывает
btn.listeners.click[0](); ok(list.hidden===false && btn.getAttribute('aria-expanded')==='true','открылся по клику');
global.activeElement=oIs; list.listeners.keydown[0]({key:'Escape',preventDefault:function(){}});
ok(list.hidden===true && btn.getAttribute('aria-expanded')==='false','Escape закрыл список');
// ссылка-опция (переключатель проекта) уводит на страницу
var pr=new El('div',{'data-ui-select':''}); var pb=new El('button',{'class':'ui-select__button'}); var pl=new El('ul',{'class':'ui-select__list'}); pl.hidden=true; var po=opt('realt','','Реальт'); po.attrs['data-href']='/p/realt/upload'; pl.children.push(po); pr.children.push(pb,pl); all.push(pr);
eval(src); pl.listeners.click[0]({target:po}); ok(window.location==='/p/realt/upload','опция-ссылка ведёт на страницу другого проекта');
print("OK: "+assertCount+" проверок JS пройдено");
