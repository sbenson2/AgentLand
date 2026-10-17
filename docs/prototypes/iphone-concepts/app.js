const iconPaths = {
  chat: '<path d="M5 5.5h11a3 3 0 0 1 3 3v5a3 3 0 0 1-3 3H9l-4 3v-3a3 3 0 0 1-3-3v-5a3 3 0 0 1 3-3Z"/><path d="M8 2.5h9a4 4 0 0 1 4 4v5"/>',
  terminal: '<path d="m4 6 5 4-5 4"/><path d="M11 15h7"/><rect x="2.5" y="3" width="19" height="16" rx="2.5"/>',
  files: '<path d="M3 7.5h7l2 2H21v9H3z"/><path d="M3 7.5V5a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v2.5"/>',
  resume: '<path d="M4.5 8A8 8 0 1 1 3 13"/><path d="M3 5v4h4M12 7v5l3 2"/>',
  workspace: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="m19.4 15 .1.1a1.7 1.7 0 0 1-2.4 2.4L17 17.4a1.7 1.7 0 0 0-2.9 1.2v.2a1.7 1.7 0 0 1-3.4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a1.7 1.7 0 0 1 0-3.4h.2A1.7 1.7 0 0 0 5.4 5.8l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.7 1.7 0 0 0 2.9-1.2V2a1.7 1.7 0 0 1 3.4 0v.2A1.7 1.7 0 0 0 17 3.4l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a1.7 1.7 0 0 1 0 3.4h-.2a1.7 1.7 0 0 0-1.2 2.9Z"/>',
};
const actions = [
  {name:'New Chat',icon:'chat'}, {name:'New Terminal',icon:'terminal'},
  {name:'Browse Files',icon:'files'}, {name:'Resume Work',icon:'resume'},
  {name:'Open Workspace',icon:'workspace'}, {name:'Settings',icon:'settings'}
];
const workspaces = ['AgentLand','Website refresh','Solo chats'];
const tasksByWorkspace = {
  'AgentLand': [
    {id:'home',title:'Home',kind:'home',sub:'AgentLand'},
    {id:'signin',title:'Fix sign-in callback',kind:'chat',sub:'AgentLand · waiting for review',mark:'wait'},
    {id:'readme',title:'README.md',kind:'file',sub:'AgentLand · docs'},
    {id:'terminal',title:'Terminal',kind:'terminal',sub:'AgentLand · ~/Developer/AgentLand'}
  ],
  'Website refresh': [
    {id:'home',title:'Home',kind:'home',sub:'Website refresh'},
    {id:'hero',title:'Update landing copy',kind:'chat',sub:'Website refresh · running',mark:'run'},
    {id:'styles',title:'tokens.css',kind:'file',sub:'Website refresh · src/styles'},
    {id:'terminal',title:'Terminal',kind:'terminal',sub:'Website refresh · ~/Sites/refresh'}
  ],
  'Solo chats': [
    {id:'home',title:'Home',kind:'home',sub:'Solo chats'},
    {id:'draft',title:'Outline release notes',kind:'chat',sub:'Standalone chat'},
    {id:'notes',title:'Untitled note',kind:'file',sub:'Standalone chat · local'}
  ]
};
const state = new WeakMap();

function icon(name){return `<svg class="action-icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${iconPaths[name]}</svg>`}
function titleArt(uid){return `<svg class="home-title" viewBox="0 0 300 86" role="img" aria-label="AgentLand"><defs><path id="word-arc-${uid}" d="M13,72 Q150,-7 287,72"/></defs><text fill="currentColor" font-family="Holtwood,Georgia,serif" font-size="28" letter-spacing="1"><textPath href="#word-arc-${uid}" startOffset="50%" text-anchor="middle">AGENTLAND</textPath></text></svg>`}
function tabsFor(el){const s=state.get(el);return [...tasksByWorkspace[s.workspace],...(s.extraTabs[s.workspace]||[])]}
function currentTask(el){const s=state.get(el);return tabsFor(el).find(t=>t.id===s.selected)||tabsFor(el)[0]}
function revealSelectedTab(row){
  const selected=row.querySelector('.selected');if(!selected)return;
  const bounds=row.getBoundingClientRect(),tab=selected.getBoundingClientRect();
  if(tab.left<bounds.left)row.scrollLeft+=tab.left-bounds.left;
  else if(tab.right>bounds.right)row.scrollLeft+=tab.right-bounds.right;
}

function drawTabs(el){
  const s=state.get(el), tabs=el.querySelectorAll('[data-tabs]');
  tabs.forEach(row=>{
    row.innerHTML=tabsFor(el).map(t=>`<button class="task-tab ${t.id===s.selected?'selected':''} ${t.kind==='home'?'tab-home':''}" type="button" data-tab="${t.id}" title="${t.title}" aria-label="${t.title}${t.mark?' — '+(t.mark==='run'?'running':'waiting for review'):''}" aria-current="${t.id===s.selected?'page':'false'}">${t.kind==='home'?'<svg class="tab-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m3 10 9-7 9 7v10h-6v-7H9v7H3z"/></svg>':''}<span class="tab-label">${t.title}</span>${t.mark?`<span class="tab-dot" aria-hidden="true"></span>`:''}</button>`).join('');
    revealSelectedTab(row);
  });
}
function draw(el){
  const s=state.get(el), view=el.querySelector('[data-view]'), scr=el.querySelector('[data-screen]');
  const task=currentTask(el);
  scr.dataset.kind=task.kind;
  const menu=el.querySelector('[data-task-menu]');menu.hidden=task.kind==='home';menu.setAttribute('aria-label',`Actions for ${task.title}`);
  drawTabs(el);
  if(task.kind==='home') view.innerHTML=homeMarkup(el);
  else if(task.kind==='chat') view.innerHTML=chatMarkup(task);
  else if(task.kind==='file') view.innerHTML=fileMarkup(task);
  else if(task.kind==='terminal') view.innerHTML=terminalMarkup(task);
  else if(task.kind==='settings') view.innerHTML=settingsMarkup();
  view.scrollTop=0;
}
function homeMarkup(el){
  const c=el.dataset.concept,s=state.get(el),context=`<p class="home-context">${s.workspace==='Solo chats'?'Standalone chats':s.workspace+' workspace'}</p>`,brand=`${titleArt(s.uid)}<img class="tent" src="assets/tent-tone.png" alt="">`;
  if(c==='b') return `<div class="home-view home-b">${brand}${context}<div class="action-grid compact"><button class="action primary" data-action="New Chat">${icon('chat')}<span>New Chat</span><span class="chev" aria-hidden="true">›</span></button><button class="action primary resume-primary" data-action="Resume Work">${icon('resume')}<span>Resume Work</span><span class="chev" aria-hidden="true">›</span></button>${actions.filter(a=>!['New Chat','Resume Work'].includes(a.name)).map(a=>`<button class="action secondary" data-action="${a.name}">${icon(a.icon)}<span>${a.name}</span></button>`).join('')}</div></div>`;
  if(c==='c') return `<div class="home-view home-c"><div class="home-c-head">${brand}</div>${context}<div class="action-sections"><section class="action-section"><h3>Start</h3><div class="action-list">${actions.slice(0,2).map(listAction).join('')}</div></section><section class="action-section"><h3>Find work</h3><div class="action-list">${actions.slice(2,5).map(listAction).join('')}</div></section><section class="action-section"><h3>Preferences</h3><div class="action-list">${listAction(actions[5])}</div></section></div></div>`;
  return `<div class="home-view">${brand}${context}<div class="action-grid">${actions.map(a=>`<button class="action" data-action="${a.name}">${icon(a.icon)}<span>${a.name}</span></button>`).join('')}</div></div>`;
}
function listAction(a){return `<button class="list-action" data-action="${a.name}">${icon(a.icon)}<span>${a.name}</span><span class="chev" aria-hidden="true">›</span></button>`}
function chatMarkup(task){
  const resume=task.kind==='chat'&&task.id!=='newchat';
  const title=task.title;
  return `<div class="task-head"><div><h2>${title}</h2><p>${task.sub}</p></div><span class="task-state">${task.mark==='run'?'Running':'Open'}</span></div><div class="chat-thread">${resume?`<div class="message user">Can you trace the callback after sign-in and check the redirect test?</div><div class="message agent"><div class="message-label">AgentLand</div><p>The callback reaches the workspace route. The failing case is a missing return path when the invitation link opens in a fresh session.</p><ul><li>Keep the invite destination through sign-in.</li><li>Return to the requested workspace after pairing.</li></ul><div class="file-card"><strong>Changed file · LoginRouter.swift</strong><p>returnPath = invitation.destination<br>resume(returnPath)</p><button class="inline-link" data-action="Browse Files">Browse related files</button></div></div><div class="message user">That matches what I saw. Keep the workspace choice explicit.</div><div class="message agent"><div class="message-label">AgentLand</div><p>Understood. I’ll show the destination before continuing.</p></div>`:`<div class="message agent"><div class="message-label">New chat</div><p>Start a conversation about the work in ${task.workspace||'this workspace'}.</p></div>`}</div><div class="composer"><span>Message AgentLand…</span><button class="send-button" aria-label="Send sample message">↑</button></div>`;
}
function fileMarkup(task){
  const isReadme=task.id==='readme';
  return `<div class="task-head"><div><h2>${isReadme?'README.md':task.title}</h2><p>${task.sub}</p></div><span class="task-state">${isReadme?'Saved':'File'}</span></div>${isReadme?`<p style="font-size:16px;line-height:1.45">AgentLand keeps a workspace and its open work together. This file is a sample view for the navigation prototype.</p><div class="file-card"><strong>Project notes</strong><p>docs/ · shared/ · ios/</p><button class="inline-link" data-action="Browse Files">Browse project files</button></div>`:`<div class="file-tree">${['Sources','Tests','docs','README.md','Package.swift'].map((f,i)=>`<button class="file-row" data-file="${f}"><span class="file-type">${i<3?'▱':'▤'}</span>${f}<span>${i<3?'Folder':'File'}</span></button>`).join('')}</div><div class="file-card"><strong>Selected · README.md</strong><p># AgentLand\nOpen a workspace to see its active tasks and files.</p></div>`}`;
}
function terminalMarkup(task){return `<div class="task-head"><div><h2>Terminal</h2><p>${task.sub}</p></div><span class="task-state">Connected</span></div><div class="terminal-top">Recent output</div><div class="terminal-lines"><span>~/Developer/AgentLand $</span> git status<br>On branch main<br>Changes not staged for commit:<br>&nbsp;&nbsp;modified: docs/README.md<br><br><span>~/Developer/AgentLand $</span> swift test<br><b>Test Suite 'AgentLandTests' passed</b><br>Executed 18 tests · 0 failures<br><br><span>~/Developer/AgentLand $</span> <b>▍</b></div><div class="terminal-toolbar"><button data-action="New Terminal">New terminal</button><button data-action="Browse Files">Browse files</button></div>`}
function settingsMarkup(){return `<div class="task-head"><div><h2>Settings</h2><p>AgentLand on this device</p></div></div><div class="settings-list">${['Connection','Security','Notifications','Appearance'].map(x=>`<button class="file-row" data-setting="${x}">${x}<span>›</span></button>`).join('')}</div><div class="file-card"><strong>Appearance</strong><p>Use the page control to compare the same layout in paper and slate.</p><button class="inline-link" data-toggle-theme>Switch appearance</button></div>`}

function presentSheet(el,markup,kind,trigger){
  const s=state.get(el),layer=el.querySelector('[data-sheet]');
  if(layer.hidden)s.returnFocus=trigger||document.activeElement;
  s.sheetKind=kind;layer.innerHTML=markup;layer.hidden=false;
  [...el.querySelector('[data-screen]').children].forEach(child=>{if(child!==layer)child.inert=true});
  el.querySelector('[data-open-work]').setAttribute('aria-expanded',String(kind==='work'));
  el.querySelector('[data-task-menu]').setAttribute('aria-expanded',String(kind==='task'));
  layer.querySelector(kind==='work'?'input':'[data-close-sheet]').focus({preventScroll:true});
}
function openWork(el,trigger){
  const s=state.get(el), layer=el.querySelector('[data-sheet]');
  presentSheet(el,`<div class="work-sheet" role="dialog" aria-modal="true" aria-labelledby="sheet-title-${s.uid}"><div class="sheet-head"><h2 id="sheet-title-${s.uid}">Open Work</h2><button class="sheet-close" data-close-sheet aria-label="Close Open Work">×</button></div><p class="sheet-context">${s.workspace==='Solo chats'?'Standalone chats':s.workspace+' workspace'}</p><label class="sr-only" for="search-${s.uid}">Search work and workspaces</label><input class="sheet-search" id="search-${s.uid}" type="search" placeholder="Search workspaces and tasks" autocomplete="off"><div class="workspace-switch" role="group" aria-label="Choose workspace">${workspaces.map(w=>`<button class="workspace-chip ${w===s.workspace?'active':''}" data-workspace="${w}" aria-pressed="${w===s.workspace}">${w}</button>`).join('')}</div><div class="work-list">${workMarkup(el)}</div></div>`,'work',trigger);
  layer.querySelector('input').value=s.search;
}
function openTaskMenu(el,trigger){
  const s=state.get(el),task=currentTask(el);
  presentSheet(el,`<div class="work-sheet task-actions" role="dialog" aria-modal="true" aria-labelledby="task-actions-${s.uid}"><div class="sheet-head"><h2 id="task-actions-${s.uid}">${task.title}</h2><button class="sheet-close" data-close-sheet aria-label="Close task actions">×</button></div><p class="sheet-context">${task.sub}</p><button class="list-action" data-open-work>${icon('resume')}<span>Open Work</span><span class="chev" aria-hidden="true">›</span></button>${task.kind==='chat'||task.kind==='terminal'?`<button class="list-action" data-action="Browse Files">${icon('files')}<span>Browse Files</span><span class="chev" aria-hidden="true">›</span></button>`:''}<button class="list-action" data-tab="home">${icon('workspace')}<span>Go to Home</span><span class="chev" aria-hidden="true">›</span></button></div>`,'task',trigger);
}
function workMarkup(el){
  const s=state.get(el), q=s.search.trim().toLowerCase();
  const groups=[{label:s.workspace==='Solo chats'?'Standalone chats':s.workspace,items:tabsFor(el)},...workspaces.filter(w=>w!==s.workspace).map(w=>({label:w,items:[...tasksByWorkspace[w],...(s.extraTabs[w]||[])].filter(t=>t.kind!=='home')}))];
  const matched=groups.map(g=>({...g,items:g.items.filter(t=>`${t.title} ${t.sub} ${g.label}`.toLowerCase().includes(q))})).filter(g=>g.items.length);
  if(!matched.length)return '<p class="empty-search">No matching work. Try a task or workspace name.</p>';
  return matched.map(g=>`<section><h3 class="work-group-title">${g.label}</h3>${g.items.map(t=>{const workspace=g.label==='Standalone chats'?'Solo chats':g.label,selected=workspace===s.workspace&&t.id===s.selected;return `<button class="work-row ${selected?'selected':''}" data-pick="${t.id}" data-pick-workspace="${workspace}" aria-current="${selected?'page':'false'}"><span class="row-mark" aria-hidden="true"></span><span class="row-main"><strong>${t.title}</strong><small>${t.sub}</small></span><span aria-hidden="true">${selected?'✓':'›'}</span></button>`}).join('')}</section>`).join('');
}
function closeWork(el,restoreFocus=true){
  const s=state.get(el),layer=el.querySelector('[data-sheet]');if(layer.hidden)return;
  layer.hidden=true;[...el.querySelector('[data-screen]').children].forEach(child=>child.inert=false);
  el.querySelectorAll('[data-open-work],[data-task-menu]').forEach(b=>b.setAttribute('aria-expanded','false'));
  if(restoreFocus)(s.returnFocus?.isConnected&&!s.returnFocus.hidden?s.returnFocus:el.querySelector('[data-open-work]')).focus({preventScroll:true});
  s.sheetKind=null;s.returnFocus=null;
}
function setTask(el,id){
  const s=state.get(el),destinations={newchat:{id:'newchat',title:'New Chat',kind:'chat',sub:`${s.workspace} · new conversation`,workspace:s.workspace},newterminal:{id:'newterminal',title:'Terminal · new',kind:'terminal',sub:`${s.workspace} · sample shell`},files:{id:'files',title:'Files',kind:'file',sub:`${s.workspace} · project files`},settings:{id:'settings',title:'Settings',kind:'settings',sub:'AgentLand on this device'}};
  if(destinations[id]&&!tabsFor(el).some(t=>t.id===id))(s.extraTabs[s.workspace]||=([])).push(destinations[id]);
  s.selected=id;closeWork(el,false);draw(el);el.querySelector('.task-tab.selected').focus({preventScroll:true});
}
function action(el,name,trigger){
  const s=state.get(el);
  if(name==='New Chat')setTask(el,'newchat');
  else if(name==='New Terminal')setTask(el,'newterminal');
  else if(name==='Browse Files')setTask(el,'files');
  else if(name==='Resume Work'){const recent=tabsFor(el).find(task=>task.kind==='chat');if(recent)setTask(el,recent.id);else openWork(el)}
  else if(name==='Open Workspace')openWork(el,trigger);
  else if(name==='Settings')setTask(el,'settings');
}
document.querySelectorAll('[data-concept]').forEach((el,index)=>{
  state.set(el,{uid:`${index+1}`,workspace:'AgentLand',selected:'home',search:'',extraTabs:{},returnFocus:null,sheetKind:null});
  draw(el);
  new ResizeObserver(()=>el.querySelectorAll('[data-tabs]').forEach(revealSelectedTab)).observe(el.querySelector('[data-tabs]'));
  el.addEventListener('click',event=>{
    if(event.target===el.querySelector('[data-sheet]')){closeWork(el);return}
    const t=event.target.closest('button');if(!t)return;
    if(t.matches('[data-open-work]')){openWork(el,t);return}
    if(t.matches('[data-task-menu]')){openTaskMenu(el,t);return}
    if(t.matches('[data-close-sheet]')){closeWork(el);return}
    if(t.matches('[data-workspace]')){const s=state.get(el);s.workspace=t.dataset.workspace;s.selected='home';s.search=el.querySelector('.sheet-search')?.value||'';draw(el);openWork(el);el.querySelector('.workspace-chip.active').focus({preventScroll:true});return}
    if(t.matches('[data-pick]')){const s=state.get(el);s.workspace=t.dataset.pickWorkspace;setTask(el,t.dataset.pick);return}
    if(t.matches('[data-tab]')){setTask(el,t.dataset.tab);return}
    if(t.matches('[data-action]')){action(el,t.dataset.action,t);return}
    if(t.matches('[data-toggle-theme]'))document.querySelector('.theme-toggle').click();
    if(t.matches('[data-file]')){const title=t.dataset.file;el.querySelector('.file-card').innerHTML=`<strong>Selected · ${title}</strong><p>${title==='README.md'?'# AgentLand\nA shared workspace for active work.':`Sample ${title.toLowerCase()} content`}</p><button class="inline-link" data-action="Resume Work">Return to recent work</button>`;return}
    if(t.matches('[data-setting]')){const title=t.dataset.setting;const card=el.querySelector('.file-card');if(card)card.innerHTML=`<strong>${title}</strong><p>Sample ${title.toLowerCase()} settings are shown in this prototype.</p><button class="inline-link" data-toggle-theme>Compare appearance</button>`;return}
    if(t.matches('.send-button')){const composer=t.closest('.composer');composer.innerHTML='<span>Sample message ready to send</span><button class="send-button" aria-label="Return to Home" data-tab="home">✓</button>';return}
  });
  el.addEventListener('input',event=>{if(event.target.matches('.sheet-search')){const s=state.get(el);s.search=event.target.value;const list=el.querySelector('.work-list');list.innerHTML=workMarkup(el)}});
  el.addEventListener('keydown',event=>{
    const layer=el.querySelector('[data-sheet]');if(layer.hidden)return;
    if(event.key==='Escape'){event.preventDefault();closeWork(el);return}
    if(event.key==='Tab'){
      const controls=[...layer.querySelectorAll('button,input')].filter(control=>!control.hidden),first=controls[0],last=controls.at(-1);
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
    }
  });
});
document.addEventListener('click',event=>{
  const theme=event.target.closest('.theme-toggle');if(theme){const dark=document.body.classList.toggle('dark');theme.setAttribute('aria-pressed',String(dark));theme.setAttribute('aria-label',dark?'Switch to light appearance':'Switch to dark appearance');theme.querySelector('.theme-label').textContent=dark?'Light appearance':'Dark appearance';return}
});
