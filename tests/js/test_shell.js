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
function door(platform, accept){ var d=new El('div',{'data-door':'','data-platform':platform});
  var b=new El('button',{'data-needs-cabinet':''}); var h=new El('p',{'data-cabinet-hint':''}); h.textContent='Сначала выберите кабинет.';
  var form=new El('form',{'data-door-form':''}); var inp=new El('input',{'data-door-file':'','accept':accept||'.xlsx'}); inp.files=[];
  var msg=new El('p',{'data-door-message':''}); msg.hidden=true;
  form.children.push(inp,b,msg); d.children.push(form,h); d.btn=b; d.hint=h; d.form=form; d.input=inp; d.msg=msg; return d; }
var dWb=door('wb'), dOz=door('ozon'), mirror=new El('input',{'data-cabinet-mirror':''});
// дверь без площадки (банковская выписка 1С, только .txt)
var dBank=door('', '.txt'); delete dBank.attrs['data-platform'];
var all=[root,dWb,dOz,dBank,mirror];
global.document={ querySelector:function(s){ return this.querySelectorAll(s)[0]||null },
  querySelectorAll:function(s){ var out=[]; all.forEach(function(e){ if(e._m(s)) out.push(e); e._q(s).forEach(function(c){out.push(c)}); }); return out; },
  addEventListener:function(){} };
global.window={location:''};
var src=readFile(ARGS_SHELL); eval(src);
function submit(d){ var prevented=false; d.form.listeners.submit.forEach(function(f){ f({preventDefault:function(){prevented=true}}) }); return prevented; }
// начальное состояние: ничего не выбрано — кнопки disabled, подсказка есть
ok(!dWb.btn.disabled && !dOz.btn.disabled,'кнопки НЕ блокируются (заблокированная кнопка молча ничего не делала — баг 2026-10-02)');
ok(dWb.hint.textContent==='Сначала выберите кабинет.','подсказка про кабинет есть');
// нажали «Загрузить» без кабинета: форма не уходит, причина показана, переключатель подсвечен
ok(submit(dWb)===true,'без кабинета форма WB не отправляется');
ok(dWb.msg.hidden===false && /выберите кабинет/.test(dWb.msg.textContent),'сообщение «выберите кабинет» показано: '+dWb.msg.textContent);
ok(root.classList.contains('ui-select--attention'),'переключатель кабинета подсвечен');
// выбираем ARB (только WB)
list.listeners.click[0]({target:oArb});
ok(mirror.value==='ARB','hidden-зеркало получило кабинет');
ok(val.textContent==='ARB','кнопка показывает выбранное');
ok(oArb.getAttribute('aria-selected')==='true' && oCs.getAttribute('aria-selected')==='false','aria-selected переключился');
ok(dWb.btn.disabled===false,'WB-дверь включена у WB-кабинета');
ok(dOz.classList.contains('door-unavailable'),'Ozon-дверь приглушена у WB-only кабинета');
ok(!root.classList.contains('ui-select--attention') && dWb.msg.hidden===true,'выбор кабинета снимает подсветку и сообщение');
dWb.input.files=[{name:'Отчёт №1.xlsx'}]; ok(submit(dWb)===false,'WB-дверь + .xlsx + кабинет WB: форма уходит');
dWb.input.files=[{name:'выписка.csv'}]; ok(submit(dWb)===true && /выписка\.csv/.test(dWb.msg.textContent) && /\.xlsx/.test(dWb.msg.textContent),'чужое расширение: форма не уходит, имя файла в сообщении: '+dWb.msg.textContent);
dWb.input.files=[{name:'ОТЧЁТ.XLSX'}]; ok(submit(dWb)===false && dWb.msg.hidden===true,'расширение без учёта регистра');
dOz.input.files=[{name:'a.xlsx'}]; ok(submit(dOz)===true && /нет площадки Ozon/.test(dOz.msg.textContent),'у WB-кабинета Ozon-дверь не отправляется, объясняя почему');
ok(/нет площадки Ozon/.test(dOz.hint.textContent),'подсказка объясняет почему: '+dOz.hint.textContent);
// CloudSix — обе площадки
list.listeners.click[0]({target:oCs});
ok(!dOz.classList.contains('door-unavailable') && dOz.hint.textContent==='','обе двери доступны у кабинета с двумя площадками');
dOz.input.files=[{name:'a.xlsx'}]; ok(submit(dOz)===false,'CloudSix: Ozon-дверь отправляется');
// Isonic — только Ozon
list.listeners.click[0]({target:oIs});
ok(dWb.classList.contains('door-unavailable') && !dOz.classList.contains('door-unavailable'),'Isonic: WB приглушена, Ozon доступна');
dWb.input.files=[{name:'a.xlsx'}]; ok(submit(dWb)===true && /нет площадки WB/.test(dWb.msg.textContent),'Isonic: WB-дверь не отправляется');
// дверь без кабинета (банк 1С, .txt): кабинет не нужен, а расширение проверяется
dBank.input.files=[{name:'выписка.pdf'}]; ok(submit(dBank)===true && /\.txt/.test(dBank.msg.textContent),'банк: .pdf не уходит');
dBank.input.files=[{name:'Выписка.TXT'}]; ok(submit(dBank)===false,'банк: .txt уходит без кабинета');
// клавиатура: Escape закрывает
btn.listeners.click[0](); ok(list.hidden===false && btn.getAttribute('aria-expanded')==='true','открылся по клику');
global.activeElement=oIs; list.listeners.keydown[0]({key:'Escape',preventDefault:function(){}});
ok(list.hidden===true && btn.getAttribute('aria-expanded')==='false','Escape закрыл список');
// ссылка-опция (переключатель проекта) уводит на страницу
var pr=new El('div',{'data-ui-select':''}); var pb=new El('button',{'class':'ui-select__button'}); var pl=new El('ul',{'class':'ui-select__list'}); pl.hidden=true; var po=opt('realt','','Реальт'); po.attrs['data-href']='/p/realt/upload'; pl.children.push(po); pr.children.push(pb,pl); all.push(pr);
eval(src); pl.listeners.click[0]({target:po}); ok(window.location==='/p/realt/upload','опция-ссылка ведёт на страницу другого проекта');
print("OK: "+assertCount+" проверок JS пройдено");
