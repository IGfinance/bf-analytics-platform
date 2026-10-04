// Проверка логики shell.js: выпадающий список, выбор кабинета → двери по площадкам (ТЗ 04, блок C).
load(ARGS_DOMSTUB);
var assertCount=0; function ok(c,m){ assertCount++; if(!c){ print("FAIL: "+m); throw new Error(m);} }
// --- разметка: переключатель кабинета + три кабинетные двери + одна без площадки
var root=new El('div',{'data-ui-select':'','data-cabinet-select':''});
var btn=new El('button',{'class':'ui-select__button','aria-expanded':'false'});
var val=new El('span',{'data-ui-select-value':''}); val.classList=val.classList; btn.children.push(val);
var list=new El('ul',{'class':'ui-select__list'}); list.hidden=true;
function opt(v,meta,label){ var o=new El('li',{'class':'ui-select__option','data-value':v,'data-meta':meta,'aria-selected':'false'}); var sp=new El('span'); sp.textContent=label; o.children.push(sp); o.querySelector=function(s){return s==='span'?sp:null}; o.closest=function(){return o}; o.click=function(){ list.listeners.click[0]({target:o}) }; return o; }
var oArb=opt('ARB','wb','ARB'), oCs=opt('CloudSix','ozon,wb','CloudSix'), oIs=opt('Isonic','ozon','Isonic');
list.children.push(oArb,oCs,oIs); root.children.push(btn,list);
function door(platform, accept){ var d=new El('div',{'data-door':'','data-platform':platform,'data-detect-url':'/detect/'+platform});
  var b=new El('button',{'data-needs-cabinet':''}); var h=new El('p',{'data-cabinet-hint':''}); h.textContent='Кабинет определится по файлу сам; если не получится — выберите его справа вверху страницы.';
  var form=new El('form',{'data-door-form':''}); var inp=new El('input',{'data-door-file':'','accept':accept||'.xlsx','name':'files'}); inp.files=[];
  var msg=new El('p',{'data-door-message':''}); msg.hidden=true; var det=new El('p',{'data-door-detect':''}); det.hidden=true;
  form.children.push(inp,b,det,msg); d.children.push(form,h); d.btn=b; d.hint=h; d.form=form; d.input=inp; d.msg=msg; d.det=det; return d; }
var dWb=door('wb'), dOz=door('ozon'), mirror=new El('input',{'data-cabinet-mirror':''});
// дверь без площадки (банковская выписка 1С, только .txt)
var dBank=door('', '.txt'); delete dBank.attrs['data-platform']; delete dBank.attrs['data-detect-url'];
var all=[root,dWb,dOz,dBank,mirror];
global.document={ querySelector:function(s){ return this.querySelectorAll(s)[0]||null },
  querySelectorAll:function(s){ var out=[]; all.forEach(function(e){ if(e._m(s)) out.push(e); e._q(s).forEach(function(c){out.push(c)}); }); return out; },
  addEventListener:function(){} };
global.window={location:''};
var src=readFile(ARGS_SHELL); eval(src);
function P(v){ this.v=v; } P.prototype.then=function(f){ var o=f(this.v); return (o instanceof P)?o:new P(o); }; P.prototype.catch=function(){ return this; };
var fetchCalls=[], nextResponse=null;
global.FormData=function(){ this.items=[]; this.append=function(k,v){ this.items.push([k,v]); }; };
global.fetch=function(url,opts){ fetchCalls.push({url:url,opts:opts}); return new P({json:function(){ return new P(nextResponse); }}); };
function attach(d,files){ d.input.files=files; d.input.listeners.change.forEach(function(f){ f({}); }); }
function submit(d){ var prevented=false; d.form.listeners.submit.forEach(function(f){ f({preventDefault:function(){prevented=true}}) }); return prevented; }
// начальное состояние: ничего не выбрано — кнопки disabled, подсказка есть
ok(!dWb.btn.disabled && !dOz.btn.disabled,'кнопки НЕ блокируются (заблокированная кнопка молча ничего не делала — баг 2026-10-02)');
ok(/определится по файлу/.test(dWb.hint.textContent),'подсказка: кабинет определится по файлу');
// нажали «Загрузить» без кабинета: форма УХОДИТ — кабинет определит сервер по файлу (или вернёт просьбу выбрать вручную)
dWb.input.files=[{name:'Отчёт №1.xlsx'}]; ok(submit(dWb)===false && dWb.msg.hidden===true,'без кабинета форма WB уходит на сервер, лишних сообщений нет');
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
// ---- автоопределение кабинета при прикреплении файла ----
list.listeners.click[0]({target:oCs});  // CloudSix (WB + Ozon): файл WB-двери допустим
fetchCalls.length=0; nextResponse={cabinet:'ARB',message:'по номеру отчёта № 587583997 — он уже есть в данных кабинета «ARB»'};
attach(dWb,[{name:'Отчёт №587583997_1.xlsx'}]);
ok(fetchCalls.length===1 && fetchCalls[0].url==='/detect/wb','при прикреплении файла уходит запрос на адрес двери: '+JSON.stringify(fetchCalls.map(function(c){return c.url})));
ok(fetchCalls[0].opts.body.items.length===1 && fetchCalls[0].opts.body.items[0][0]==='files','файл отправлен под именем поля формы');
ok(mirror.value==='ARB' && val.textContent==='ARB','кабинет ARB подставлен в переключатель сам (был CloudSix)');
ok(dWb.det.hidden===false && /ARB/.test(dWb.det.textContent) && /номеру отчёта/.test(dWb.det.textContent),'причина показана: '+dWb.det.textContent);
ok(dWb.det.classList.contains('text-success-text'),'успех — зелёным');
// не определился: выбор не меняется, объяснение серым
nextResponse={cabinet:null,message:'Кабинет по файлу определить не удалось.'};
attach(dWb,[{name:'другой.xlsx'}]);
ok(mirror.value==='ARB','не определился — выбранный кабинет не трогаем');
ok(/определить не удалось/.test(dWb.det.textContent) && /Выберите его справа/.test(dWb.det.textContent) && !dWb.det.classList.contains('text-success-text'),'просьба выбрать вручную: '+dWb.det.textContent);
// определился кабинет, которого нет в списке переключателя
nextResponse={cabinet:'Zed',message:'x'}; attach(dWb,[{name:'z.xlsx'}]);
ok(/которого нет в списке/.test(dWb.det.textContent),'кабинет не из списка — объяснение');
// файл не того типа: запрос не уходит, сразу понятное сообщение
fetchCalls.length=0; attach(dWb,[{name:'выписка.csv'}]);
ok(fetchCalls.length===0 && dWb.msg.hidden===false && /\.xlsx/.test(dWb.msg.textContent) && dWb.det.hidden===true,'чужое расширение при выборе файла: без запроса, сообщение сразу');
// дверь без площадки (банк) автоопределения не запрашивает
fetchCalls.length=0; attach(dBank,[{name:'a.txt'}]); ok(fetchCalls.length===0,'у двери без кабинета запроса автоопределения нет');
// клавиатура: Escape закрывает
btn.listeners.click[0](); ok(list.hidden===false && btn.getAttribute('aria-expanded')==='true','открылся по клику');
global.activeElement=oIs; list.listeners.keydown[0]({key:'Escape',preventDefault:function(){}});
ok(list.hidden===true && btn.getAttribute('aria-expanded')==='false','Escape закрыл список');
// ссылка-опция (переключатель проекта) уводит на страницу
var pr=new El('div',{'data-ui-select':''}); var pb=new El('button',{'class':'ui-select__button'}); var pl=new El('ul',{'class':'ui-select__list'}); pl.hidden=true; var po=opt('realt','','Реальт'); po.attrs['data-href']='/p/realt/upload'; pl.children.push(po); pr.children.push(pb,pl); all.push(pr);
eval(src); pl.listeners.click[0]({target:po}); ok(window.location==='/p/realt/upload','опция-ссылка ведёт на страницу другого проекта');
print("OK: "+assertCount+" проверок JS пройдено");
