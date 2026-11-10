'use strict';
let activeTab='notes', route='notes', shelfFiles=[], unreadApps=[], agentState={enabled:false,windows:[]};
let filePointer=null,fileDragging=false,lastFileDrag=0,toastTimer,dropWasOpen=false,dropPreviousTab='notes',dropCommitted=false;
window.islandDropping=false;
function syncViews(){
  dock.dataset.view=route;document.documentElement.style.setProperty('--expanded-height',({notes:240,files:240,tools:220,settings:300})[route]+'px');syncSurface();
  $('#quota-refresh').hidden=route!=='tools'||!agentState.enabled;
  $('#note-view').hidden=route!=='notes';$('#files-view').hidden=route!=='files';$('#tools-view').hidden=route!=='tools';$('#settings-view').hidden=route!=='settings';
  $('.main-tabs').hidden=!['notes','files'].includes(route);
  $('#notes-tab').setAttribute('aria-selected',String(activeTab==='notes'));$('#files-tab').setAttribute('aria-selected',String(activeTab==='files'));
  if(['notes','files'].includes(route)){$('#note-heading').hidden=false;$('#back').hidden=true;$('#settings-button').hidden=false;$('#tools-button').hidden=!agentState.enabled}
  else{$('#note-heading').hidden=true;$('#back').hidden=false;$('#settings-button').hidden=true;$('#tools-button').hidden=true;$('#back').lastChild.textContent=route==='tools'?'额度':'设置'}
  if(route==='notes')requestAnimationFrame(()=>$$('.line textarea').forEach(resize));
}
function switchTab(tab,refresh=true){activeTab=tab;route=tab;inSettings=false;editing=false;syncViews();if(tab==='files'&&refresh)sendNative('filesRefresh')}
$('#notes-tab').addEventListener('click',()=>switchTab('notes'));$('#files-tab').addEventListener('click',()=>switchTab('files'));
document.addEventListener('settingsView',e=>{route=e.detail?'settings':activeTab;syncViews()});
function renderQuotaSummary(stale){
  const windows=(agentState.windows||[]).filter(w=>Number.isFinite(w.remaining));
  const remaining=windows.length?Math.max(0,Math.min(100,Math.min(...windows.map(w=>w.remaining)))):null;
  const readout=$('#tools-button'),value=remaining===null?'—':Math.round(remaining)+'%';
  readout.querySelector('.mini-value').textContent=(stale&&remaining!==null?'上次剩余 ':'剩余 ')+value;
  readout.querySelector('.mini-progress').style.strokeDashoffset=remaining===null?'100':String(100-remaining);
  readout.classList.toggle('quota-stale',stale);
  readout.setAttribute('aria-label','Codex Pro '+(remaining===null?'额度暂不可用':(stale?'上次额度剩余 ':'额度剩余 ')+value));
}
document.addEventListener('islandCollapsed',()=>{activeTab='notes';route='notes';inSettings=false;syncViews()});
function toast(message){clearTimeout(toastTimer);$('#toast').textContent=message;$('#toast').hidden=false;toastTimer=setTimeout(()=>$('#toast').hidden=true,4000)}
function makeButton(text,action,label){const button=document.createElement('button');button.type='button';button.className='text-button';button.textContent=text;if(label)button.setAttribute('aria-label',label);button.addEventListener('click',e=>{e.stopPropagation();action()});return button}
function renderFiles(){
  $('#file-count').textContent=shelfFiles.length||'';$('#clear-files').disabled=!shelfFiles.length;$('#drop-zone').classList.toggle('compact',shelfFiles.length>0);
  $('#file-list').replaceChildren();
  for(const file of shelfFiles){
    const row=document.createElement('div');row.className='file-row'+(file.available?'':' missing');row.dataset.file=file.id;
    const main=document.createElement('div');main.className='file-main';main.tabIndex=0;main.role='button';main.title=file.path;main.setAttribute('aria-label',file.name+(file.available?'，打开或拖出':'，原文件不可用'));
    if(file.icon){const icon=document.createElement('img');icon.src=file.icon;icon.alt='';icon.draggable=false;main.append(icon)}
    const copy=document.createElement('div');const name=document.createElement('div');name.className='file-name';name.textContent=file.name;
    const hint=document.createElement('div');hint.className='file-hint';hint.textContent=file.available?'':'不可用';hint.hidden=file.available;copy.append(name,hint);main.append(copy);row.append(main);
    main.addEventListener('click',()=>{if(Date.now()-lastFileDrag<350)return;sendNative(file.available?'fileOpen':'fileRelink',{id:file.id})});
    main.addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();sendNative(file.available?'fileOpen':'fileRelink',{id:file.id})}});
    main.addEventListener('pointerdown',e=>{if(e.button===0&&file.available)filePointer={id:file.id,x:e.clientX,y:e.clientY}});
    const actions=document.createElement('div');actions.className='file-actions';actions.append(makeButton(file.available?'定位':'重连',()=>sendNative(file.available?'fileReveal':'fileRelink',{id:file.id}),file.available?'在 Finder 中显示 '+file.name:'重新定位 '+file.name),makeButton('×',()=>sendNative('fileRemove',{id:file.id}),'移除入口 '+file.name));row.append(actions);$('#file-list').append(row);
  }
}
document.addEventListener('pointermove',e=>{if(!filePointer||fileDragging)return;if(Math.hypot(e.clientX-filePointer.x,e.clientY-filePointer.y)>=5){fileDragging=true;lastFileDrag=Date.now();sendNative('fileDrag',{id:filePointer.id})}});
document.addEventListener('pointerup',()=>{filePointer=null;if(!fileDragging)return;lastFileDrag=Date.now();fileDragging=false});
$('#choose-files').addEventListener('click',()=>{if(native)sendNative('filesChoose');else toast('文件拖放与引用由桌面应用提供')});
$('#clear-files').addEventListener('click',()=>sendNative('filesClear'));
const quotaRows=new Map();
function createQuotaRow(){
  const row=document.createElement('div');row.className='quota-dial';
  const ring=document.createElement('div');ring.className='quota-ring';ring.role='meter';ring.setAttribute('aria-valuemin','0');ring.setAttribute('aria-valuemax','100');
  const ns='http://www.w3.org/2000/svg';const svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox','0 0 120 120');svg.setAttribute('aria-hidden','true');
  for(const progress of [false,true]){const circle=document.createElementNS(ns,'circle');circle.setAttribute('cx','60');circle.setAttribute('cy','60');circle.setAttribute('r','53');circle.setAttribute('pathLength','100');circle.setAttribute('class',progress?'ring-progress':'ring-track');if(progress)circle.setAttribute('stroke-dasharray','100 100');svg.append(circle)}
  const value=document.createElement('div');value.className='ring-value';const amount=document.createElement('span');amount.className='ring-amount';const unit=document.createElement('span');unit.className='ring-unit';unit.textContent='%';value.append(amount,unit);ring.append(svg,value);
  const detail=document.createElement('div');detail.className='quota-detail';const brand=document.createElement('div');brand.className='quota-brand';brand.textContent='Codex';const period=document.createElement('div');period.className='quota-period';const reset=document.createElement('div');reset.className='dial-reset';detail.append(brand,period,reset);row.append(ring,detail);return row;
}
function renderAgents(){
  $('#quota-refresh').disabled=Boolean(agentState.checking);
  $('#codex-enabled').checked=agentState.enabled;$('#codex-enabled').disabled=!native;$('#refresh-agents').hidden=!agentState.enabled;
  const stale=Boolean(agentState.error)||Boolean(agentState.updatedAt&&agentState.updatedAt*1000<Date.now()-180000);
  $('#codex-status').textContent=!agentState.enabled?'':agentState.error||(agentState.checking&&!agentState.updatedAt?'正在同步…':'');
  renderQuotaSummary(stale);
  const details=$('#agent-details');
  if(!agentState.enabled){details.replaceChildren();quotaRows.clear();const p=document.createElement('p');p.className='empty-message';p.textContent='尚未启用额度监控';details.append(p);return}
  let grid=details.querySelector('.quota-grid');if(!grid){details.replaceChildren();grid=document.createElement('div');grid.className='quota-grid';details.append(grid)}
  const windows=agentState.windows||[];grid.dataset.count=String(windows.length);const ids=new Set(windows.map(window=>window.id));
  for(const [id,row] of quotaRows)if(!ids.has(id)){row.remove();quotaRows.delete(id)}
  windows.forEach((window,index)=>{
    let row=quotaRows.get(window.id);const fresh=!row;if(fresh){row=createQuotaRow();quotaRows.set(window.id,row)}
    if(grid.children[index]!==row)grid.insertBefore(row,grid.children[index]||null);
    const ring=row.querySelector('.quota-ring'),progress=row.querySelector('.ring-progress');const remaining=Math.max(0,Math.min(100,window.remaining));
    ring.classList.toggle('low',remaining<20);ring.classList.toggle('critical',remaining<5);row.classList.toggle('stale',stale);
    progress.style.transition=fresh?'none':'';progress.style.strokeDashoffset=String(100-remaining);progress.style.opacity=remaining===0?'0':'';
    ring.setAttribute('aria-label','Codex '+window.name+(stale?'上次剩余':'剩余'));ring.setAttribute('aria-valuenow',String(Math.round(remaining)));
    row.querySelector('.ring-amount').textContent=Math.round(remaining);row.querySelector('.quota-period').textContent=window.name;
    const ended=window.resetsAt&&window.resetsAt*1000<=Date.now();row.querySelector('.dial-reset').textContent=window.resetsAt?(ended?'等待同步':new Date(window.resetsAt*1000).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'})+' 重置'):'未返回重置时间';
  });
  let error=details.querySelector('.quota-error');if(!error){error=document.createElement('p');error.className='setting-note quota-error';details.append(error)}error.textContent=agentState.error||(!windows.length?'等待同步':stale?'上次同步的额度':'');error.hidden=!error.textContent;
}
function renderUnread(){
  $('#unread-settings').replaceChildren();$('#unread-details').replaceChildren();
  for(const app of unreadApps){
    const row=document.createElement('div');row.className='integration-row';const label=document.createElement('label');label.className='setting-label';label.textContent=app.name;
    if(app.supported){const toggle=document.createElement('input');toggle.className='switch';toggle.type='checkbox';toggle.role='switch';toggle.checked=app.enabled;toggle.setAttribute('aria-label',app.name+'未读提醒');toggle.addEventListener('change',()=>sendNative('unreadEnable',{id:app.id,enabled:toggle.checked}));label.append(toggle)}
    const reason=document.createElement('p');reason.className='setting-note';reason.textContent=app.supported?'':app.reason;reason.hidden=app.supported;row.append(label,reason);$('#unread-settings').append(row);
    if(app.enabled&&app.supported){const button=makeButton(app.name+(app.badge?' · '+app.badge:''),()=>sendNative('unreadOpen',{id:app.id}));button.classList.add('unread-app');if(app.icon){const image=document.createElement('img');image.src=app.icon;image.alt='';button.prepend(image)}$('#unread-details').append(button)}
  }
  $('#unread-details').closest('.group').hidden=!unreadApps.some(app=>app.enabled&&app.supported)
  const hasUnread=unreadApps.some(app=>app.enabled&&app.supported&&app.badge);
  const unreadButton=$('#unread-button');unreadButton.hidden=!hasUnread;unreadButton.replaceChildren();
  if(hasUnread){const app=unreadApps.find(app=>app.enabled&&app.supported&&app.badge);unreadButton.setAttribute('aria-label','打开'+app.name);unreadButton.onclick=()=>sendNative('unreadOpen',{id:app.id});if(app.icon){const icon=document.createElement('img');icon.src=app.icon;icon.alt='';icon.width=16;icon.height=16;unreadButton.append(icon)}else unreadButton.textContent='•'}

  const low=agentState.enabled&&(agentState.windows||[]).some(w=>w.remaining<20&&w.resetsAt*1000>Date.now());
  const idle=$('#idle-indicator');idle.hidden=!hasUnread&&!low;idle.classList.toggle('message',hasUnread);idle.replaceChildren();
  if(hasUnread){const app=unreadApps.find(app=>app.enabled&&app.supported&&app.badge);if(app.icon){const icon=document.createElement('img');icon.src=app.icon;icon.alt='';idle.append(icon)}idle.setAttribute('aria-label','打开'+app.name);idle.onclick=()=>sendNative('unreadOpen',{id:app.id})}
  else if(low){idle.setAttribute('aria-label','查看 Codex 额度');idle.onclick=()=>{open()}}
  dock.classList.toggle('has-message',hasUnread);
  if(['notes','files'].includes(route))$('#tools-button').hidden=!agentState.enabled;
  trigger.setAttribute('aria-label',hasUnread?'打开随手记，有未读提醒':low?'打开随手记，Codex 额度不足':'打开随手记');
}
$('#quota-refresh').addEventListener('click',()=>sendNative('agentsRefresh'));
$('#codex-enabled').addEventListener('change',e=>sendNative('agentsEnable',{enabled:e.target.checked}));$('#refresh-agents').addEventListener('click',()=>sendNative('agentsRefresh'));$('#check-unread').addEventListener('click',()=>sendNative('unreadCheck'));$('#unread-permission').addEventListener('click',()=>sendNative('unreadPermission'));
// External drags are handled by AppKit. Never interpret arbitrary HTML/URLs as file references.
document.addEventListener('dragover',e=>e.preventDefault());document.addEventListener('drop',e=>e.preventDefault());
window.islandV2={
  hover: hoverChanged,
  motionEnded(expanded){if(!expanded)finishCollapse()},
  files(value){shelfFiles=value;renderFiles()},
  dropHover(hover){if(hover){if(!window.islandDropping){dropWasOpen=opened;dropPreviousTab=activeTab;dropCommitted=false}window.islandDropping=true;open();if(inSettings)showSettings(false,false);switchTab('files');dock.classList.add('drop-active')}else{window.islandDropping=false;dock.classList.remove('drop-active');if(!dropCommitted)switchTab(dropPreviousTab);if(!dropWasOpen)queueClose()}},
  fileFocus(ids){const row=[...$('#file-list').children].find(row=>row.dataset.file===ids[0]);if(row){row.classList.add('recent');row.querySelector('.file-main').focus({preventScroll:true});const view=$('.file-scroll'),r=row.getBoundingClientRect(),v=view.getBoundingClientRect();if(r.top<v.top)view.scrollTop+=r.top-v.top;else if(r.bottom>v.bottom)view.scrollTop+=r.bottom-v.bottom;setTimeout(()=>row.classList.remove('recent'),1200)}},
  dropComplete(ids){dropCommitted=true;dropWasOpen=true;window.islandDropping=false;open();switchTab('files',false);window.islandV2.fileFocus(ids);},
  agents(value){agentState=value;renderAgents();renderUnread()},
  unread(value){unreadApps=value;renderUnread()},
  toast,
  alert(message){toast(message)},
};
window.islandHost.saveForQuit=()=>{clearTimeout(saveTimer);sendNative('save',{value:{version:2,settings,lines},quit:true})};
window.islandHost.fileDragEnded=()=>{fileDragging=false;filePointer=null;lastFileDrag=Date.now();};
if(!native){$('#unread-permission').hidden=true;$('#check-unread').disabled=true;$('#unread-settings').textContent='请在桌面应用中检查通知兼容性';$('#codex-status').textContent='请在桌面应用中连接 Codex'}
const settingsContent=$('#settings-view .settings-scroll');
const settingsGroups=[...settingsContent.children].filter(node=>node.classList.contains('group'));
for(const indexes of [[0,2,3,5],[1,4,6,7]]){const column=document.createElement('div');column.className='settings-column';for(const index of indexes)if(settingsGroups[index])column.append(settingsGroups[index]);settingsContent.append(column)}
renderFiles();renderAgents();syncViews();sendNative('ready',{edge:settings.edge});
