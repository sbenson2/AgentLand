const iconPaths = {
  circusTent: '<path d="M12 3v4M12 3h5l-2 2h-3M3 12l9-5 9 5M4 12v8h16v-8M8 20v-5l4-3 4 3v5M3 12l2 2 3-2 4 2 4-2 3 2 2-2"/>',
  circusClown: '<path d="m8 8 4-6 4 6M6 14a6 6 0 1 0 12 0 6 6 0 0 0-12 0ZM8 19l-3 3h14l-3-3M9 16q3 3 6 0"/><circle cx="9.5" cy="12" r=".6"/><circle cx="14.5" cy="12" r=".6"/><circle cx="12" cy="14" r="1"/>',
  circusTicket: '<path d="M4 5h16v4a3 3 0 0 0 0 6v4H4v-4a3 3 0 0 0 0-6ZM9 8v8M12 9h5M12 12h3M12 15h5"/>',
  circusTerminal: '<circle cx="12" cy="12" r="9"/><path d="m7 8 4 4-4 4M13 16h4M12 1v2M12 21v2"/>',
  chat: '<path d="M5 5.5h11a3 3 0 0 1 3 3v5a3 3 0 0 1-3 3H9l-4 3v-3a3 3 0 0 1-3-3v-5a3 3 0 0 1 3-3Z"/><path d="M8 2.5h9a4 4 0 0 1 4 4v5"/>',
  terminal: '<path d="m4 6 5 4-5 4"/><path d="M11 15h7"/><rect x="2.5" y="3" width="19" height="16" rx="2.5"/>',
  files: '<path d="M3 7.5h7l2 2H21v9H3z"/><path d="M3 7.5V5a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v2.5"/>',
  resume: '<path d="M4.5 8A8 8 0 1 1 3 13"/><path d="M3 5v4h4M12 7v5l3 2"/>',
  workspace: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="m19.4 15 .1.1a1.7 1.7 0 0 1-2.4 2.4L17 17.4a1.7 1.7 0 0 0-2.9 1.2v.2a1.7 1.7 0 0 1-3.4 0v-.2a1.7 1.7 0 0 0-2.9-1.2l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.7 1.7 0 0 0-1.2-2.9H4a1.7 1.7 0 0 1 0-3.4h.2A1.7 1.7 0 0 0 5.4 5.8l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.7 1.7 0 0 0 2.9-1.2V2a1.7 1.7 0 0 1 3.4 0v.2A1.7 1.7 0 0 0 17 3.4l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.7 1.7 0 0 0 1.2 2.9h.2a1.7 1.7 0 0 1 0 3.4h-.2a1.7 1.7 0 0 0-1.2 2.9Z"/>',
};
const actions = [
  {name:'New Chat',icon:'chat'}, {name:'New Terminal',icon:'terminal'},
  {name:'New Workspace',icon:'workspace'}, {name:'Resume Workspace',icon:'resume'}
];
const workspaces = ['AgentLand','Website refresh','Solo chats'];
const workspacePaths = {'AgentLand':'~/Developer/AgentLand','Website refresh':'~/Sites/refresh','Solo chats':'Local chats'};
const newWorkspaceChoices = {
  scratch:{name:'Scratch project',path:'~/Workspaces/Scratch'},
  experiment:{name:'App experiment',path:'~/Developer/AppExperiment'}
};
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
const workspaceData = {
  'AgentLand':{folders:{Sources:['LoginRouter.swift','AppModel.swift'],Tests:['WorkspaceTests.swift'],docs:['README.md']},files:['README.md','Package.swift'],changes:['Sources/LoginRouter.swift','docs/README.md'],sessions:[{id:'past-settings',title:'Review settings drawer',when:'Yesterday'},{id:'past-pairing',title:'Trace workspace pairing',when:'Monday'}]},
  'Website refresh':{folders:{src:['index.html','tokens.css'],docs:['content-notes.md']},files:['README.md'],changes:['src/index.html','src/tokens.css'],sessions:[{id:'past-copy',title:'Compare landing page copy',when:'Yesterday'},{id:'past-mobile',title:'Check mobile spacing',when:'Tuesday'}]},
  'Solo chats':{folders:{},files:['release-notes.md','meeting-notes.md'],changes:[],sessions:[{id:'past-release',title:'Draft a release summary',when:'Yesterday'},{id:'past-reading',title:'Organize reading notes',when:'Last week'}]}
};
const state = new WeakMap();

function icon(name){return `<svg class="action-icon" aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${iconPaths[name]}</svg>`}
function titleArt(uid){return `<svg class="home-title" viewBox="0 0 300 86" role="img" aria-label="AgentLand"><defs><path id="word-arc-${uid}" d="M13,72 Q150,-7 287,72"/></defs><text fill="currentColor" font-family="Holtwood,Georgia,serif" font-size="28" letter-spacing="1"><textPath href="#word-arc-${uid}" startOffset="50%" text-anchor="middle">AGENTLAND</textPath></text></svg>`}
function allTasksFor(el,workspace=state.get(el).workspace){const s=state.get(el);return [...(tasksByWorkspace[workspace]||[{id:'home',title:'Home',kind:'home'}]),...(s.extraTabs[workspace]||[])]}
function tabsFor(el){const s=state.get(el);return allTasksFor(el).filter(task=>!(s.closedTabs[s.workspace]||[]).includes(task.id))}
function currentTask(el){const s=state.get(el);return tabsFor(el).find(t=>t.id===s.selected)||tabsFor(el)[0]}
function revealSelectedTab(row){
  const selected=row.querySelector('.selected');if(!selected)return;
  const bounds=row.getBoundingClientRect(),tab=(selected.closest('.tab-group')||selected).getBoundingClientRect();
  if(tab.left<bounds.left)row.scrollLeft+=tab.left-bounds.left;
  else if(tab.right>bounds.right)row.scrollLeft+=tab.right-bounds.right;
}

function drawTabs(el){
  const s=state.get(el), tabs=el.querySelectorAll('[data-tabs]');
  tabs.forEach(row=>{
    row.innerHTML=tabsFor(el).map(t=>`<div class="tab-group ${t.id===s.selected?'selected':''}"><button class="task-tab ${t.id===s.selected?'selected':''} ${t.kind==='home'?'tab-home':''}" type="button" data-tab="${t.id}" title="${t.title}" aria-label="${t.title}${t.mark?' — '+(t.mark==='run'?'running':'waiting for review'):''}" aria-current="${t.id===s.selected?'page':'false'}">${t.kind==='home'?'<svg class="tab-icon" viewBox="0 0 24 24" aria-hidden="true"><path d="m3 10 9-7 9 7v10h-6v-7H9v7H3z"/></svg>':''}<span class="tab-label">${t.title}</span>${t.mark?`<span class="tab-dot" aria-hidden="true"></span>`:''}</button>${t.id===s.selected&&t.kind!=='home'?`<button class="tab-close" data-close-tab="${t.id}" aria-label="Close ${t.title} tab" title="Close tab">×</button>`:''}</div>`).join('');
    revealSelectedTab(row);
  });
}
function draw(el){
  const s=state.get(el), view=el.querySelector('[data-view]'), scr=el.querySelector('[data-screen]');
  s.homeEpoch++;s.homeAnimations.forEach(animation=>animation.cancel());s.homeAnimations=[];s.homeMenu=null;
  const task=currentTask(el);
  scr.dataset.kind=task.kind;
  el.querySelector('[data-workspace-title]').textContent=s.workspace||'No open workspace';
  el.querySelector('[data-current-task-title]').textContent=task.title;
  el.querySelector('[data-task-menu]').setAttribute('aria-label',`${task.title}: open tabs in ${s.workspace||'Home'}`);
  drawTabs(el);
  if(task.kind==='home') view.innerHTML=homeMarkup(el);
  else if(task.kind==='chat') view.innerHTML=chatMarkup(task);
  else if(task.kind==='file') view.innerHTML=fileMarkup(task);
  else if(task.kind==='terminal') view.innerHTML=terminalMarkup(task);
  else if(task.kind==='settings') view.innerHTML=settingsMarkup();
  view.scrollTop=0;
}
let quipFontIndex=Math.floor(Math.random()*4);
function homeMarkup(el){
  quipFontIndex=(quipFontIndex+1)%4;
  const context='Juggling three pull requests';
  return `<div class="home-view selected-home" tabindex="-1"><div class="native-scene" role="img" aria-label="AgentLand pixel wordmark above a circus tent and unicycle clown"><div class="native-wordmark"><img class="native-scene-light" src="assets/native-home-light.png" alt="" aria-hidden="true"><img class="native-scene-dark" src="assets/native-home-dark.png" alt="" aria-hidden="true"></div><div class="native-circus"><img class="native-tent native-doorway" src="assets/tent-doorway.png" alt="" aria-hidden="true"><img class="native-tent" src="assets/tent-tone.png" alt="" aria-hidden="true"><div class="native-clown" aria-hidden="true"></div></div></div><p class="home-context home-quip quip-font-${quipFontIndex}">${context}</p><div class="home-actions" data-home-actions role="group" aria-label="Home actions">${homeActionsMarkup(el)}</div></div>`;
}
function homeActionsMarkup(el){
  const s=state.get(el),menu=s.homeMenu;
  if(!menu)return `<div class="home-action-content"><div class="home-options-head" aria-hidden="true"></div><div class="action-grid">${actions.map(a=>`<button class="action" data-action="${a.name}">${icon(a.icon)}<span>${a.name}</span></button>`).join('')}</div></div>`;
  const option=(value,name,glyph,detail='')=>`<button class="action home-option" data-home-choice="${value}">${icon(glyph)}<span>${name}${detail?`<small>${detail}</small>`:''}</span></button>`;
  let options='';
  if(menu==='New Chat')options=option('chat:standalone','Standalone Chat','chat')+['OpenCode','Claude Code','Codex'].map(name=>option('chat:'+name.toLowerCase().replace(' ',''),name,'chat')).join('');
  else if(menu==='New Terminal')options=option('terminal:shell','Shell','terminal')+['OpenCode','Claude Code','Codex'].map(name=>option('terminal:'+name.toLowerCase().replace(' ',''),name,'terminal')).join('');
  else if(menu==='New Workspace')options=Object.entries(newWorkspaceChoices).map(([key,workspace])=>option('workspace:'+key,workspace.name,'workspace',workspace.path)).join('');
  else options=workspaces.map(workspace=>option('resume:'+workspace,workspace,'resume',workspacePaths[workspace])).join('');
  return `<div class="home-action-content"><div class="home-options-head"><button data-home-back aria-label="Back to Home actions">‹ Back</button><h3>${menu}</h3></div><div class="action-grid home-option-grid">${options}</div></div>`;
}
function changeHomeMenu(el,menu){
  const s=state.get(el),area=el.querySelector('[data-home-actions]');if(!area)return;
  const epoch=++s.homeEpoch;s.homeAnimations.forEach(animation=>animation.cancel());s.homeAnimations=[];area.querySelector('.home-expansion')?.remove();
  const bounds=area.getBoundingClientRect();
  if(menu){
    s.homeOriginAction=menu;
    const tile=area.querySelector(`[data-action="${menu}"]`).getBoundingClientRect();
    s.homeTileRect={left:tile.left-bounds.left,top:tile.top-bounds.top,width:tile.width,height:tile.height};
  }
  s.homeMenu=menu;el.querySelector('.selected-home').focus({preventScroll:true});
  area.inert=true;area.setAttribute('aria-busy','true');
  const focus=()=>{if(epoch!==s.homeEpoch||!area.isConnected)return;area.inert=false;area.removeAttribute('aria-busy');(menu?area.querySelector('[data-home-choice]'):area.querySelector(`[data-action="${s.homeOriginAction}"]`))?.focus({preventScroll:true})};
  const replace=()=>{s.homeMenu=menu;area.classList.toggle('has-options',!!menu);area.innerHTML=homeActionsMarkup(el);area.setAttribute('aria-label',menu||'Home actions')};
  if(matchMedia('(prefers-reduced-motion: reduce)').matches||!area.animate){replace();focus();return}
  const animate=(node,frames,duration,delay=0)=>{const animation=node.animate(frames,{duration,delay,easing:'cubic-bezier(.2,.7,.2,1)',fill:'both'});s.homeAnimations.push(animation);return animation};
  const rectangle=rect=>({left:rect.left+'px',top:rect.top+'px',width:rect.width+'px',height:rect.height+'px'});
  const full={left:0,top:0,width:bounds.width,height:bounds.height};
  const expansion=()=>{const node=document.createElement('div'),action=actions.find(item=>item.name===s.homeOriginAction);node.className='home-expansion';node.setAttribute('aria-hidden','true');node.innerHTML=icon(action.icon)+`<span>${action.name}</span>`;area.append(node);return node};
  (async()=>{
    if(menu){
      const layer=expansion();
      const fading=animate(area.querySelector('.home-action-content'),[{opacity:1},{opacity:0}],160);
      const growing=animate(layer,[rectangle(s.homeTileRect),rectangle(full)],240);
      await Promise.all([fading.finished,growing.finished]);
      if(epoch!==s.homeEpoch||!area.isConnected)return;
      replace();await animate(area.querySelector('.home-action-content'),[{opacity:0},{opacity:1}],140).finished;
    }else{
      await animate(area.querySelector('.home-action-content'),[{opacity:1},{opacity:0}],100).finished;
      if(epoch!==s.homeEpoch||!area.isConnected)return;
      replace();const layer=expansion();
      const shrinking=animate(layer,[rectangle(full),rectangle(s.homeTileRect)],220);
      const restoring=animate(area.querySelector('.home-action-content'),[{opacity:0},{opacity:1}],160,80);
      await Promise.all([shrinking.finished,restoring.finished]);layer.remove();
    }
    if(epoch!==s.homeEpoch)return;s.homeAnimations.forEach(animation=>animation.cancel());s.homeAnimations=[];focus();
  })().catch(()=>{});
}
function chooseHomeOption(el,value){
  const s=state.get(el),separator=value.indexOf(':'),kind=value.slice(0,separator),choice=value.slice(separator+1);
  if(kind==='workspace'){
    const workspace=newWorkspaceChoices[choice];if(!workspace)return;
    if(!workspaces.includes(workspace.name)){
      workspaces.push(workspace.name);workspacePaths[workspace.name]=workspace.path;
      tasksByWorkspace[workspace.name]=[{id:'home',title:'Home',kind:'home',sub:workspace.name}];
      workspaceData[workspace.name]={folders:{},files:['README.md'],changes:[],sessions:[]};
    }
    s.closedWorkspaces=s.closedWorkspaces.filter(name=>name!==workspace.name);s.workspace=workspace.name;setTask(el,'home');return;
  }
  if(kind==='resume'){
    if(!workspaces.includes(choice))return;
    s.closedWorkspaces=s.closedWorkspaces.filter(name=>name!==choice);s.workspace=choice;
    const pending=s.pendingHomeAction;s.pendingHomeAction=null;
    setTask(el,pending?'home':s.lastTaskByWorkspace[choice]||'home');if(pending)changeHomeMenu(el,pending);return;
  }
  const providers={standalone:'Standalone',shell:'Shell',opencode:'OpenCode',claudecode:'Claude Code',codex:'Codex'};
  if(!providers[choice]||!['chat','terminal'].includes(kind))return;
  if(choice==='standalone'){s.workspace='Solo chats';s.closedWorkspaces=s.closedWorkspaces.filter(name=>name!=='Solo chats')}
  const id=kind+':'+choice;
  if(!allTasksFor(el).some(task=>task.id===id))(s.extraTabs[s.workspace]||=[]).push({id,title:kind==='chat'?providers[choice]+' Chat':providers[choice]+' Terminal',kind,sub:s.workspace+' · '+(kind==='chat'?'sample conversation':workspacePaths[s.workspace]),workspace:s.workspace,newConversation:true});
  setTask(el,id);
}
function listAction(a){return `<button class="list-action" data-action="${a.name}">${icon(a.icon)}<span>${a.name}</span><span class="chev" aria-hidden="true">›</span></button>`}
function chatMarkup(task){
  const resume=task.kind==='chat'&&task.id!=='newchat'&&!task.newConversation;
  const title=task.title;
  return `<div class="task-head"><div><h2>${title}</h2><p>${task.sub}</p></div><span class="task-state">${task.mark==='run'?'Running':'Open'}</span></div><div class="chat-thread">${resume?`<div class="message user">Can you trace the callback after sign-in and check the redirect test?</div><div class="message agent"><div class="message-label">AgentLand</div><p>The callback reaches the workspace route. The failing case is a missing return path when the invitation link opens in a fresh session.</p><ul><li>Keep the invite destination through sign-in.</li><li>Return to the requested workspace after pairing.</li></ul><div class="file-card"><strong>Changed file · LoginRouter.swift</strong><p>returnPath = invitation.destination<br>resume(returnPath)</p><button class="inline-link" data-action="Browse Files">Browse related files</button></div></div><div class="message user">That matches what I saw. Keep the workspace choice explicit.</div><div class="message agent"><div class="message-label">AgentLand</div><p>Understood. I’ll show the destination before continuing.</p></div>`:`<div class="message agent"><div class="message-label">New chat</div><p>Start a conversation about the work in ${task.workspace||'this workspace'}.</p></div>`}</div><div class="composer"><span>Message AgentLand…</span><button class="send-button" aria-label="Send sample message">↑</button></div>`;
}
function fileMarkup(task){
  if(task.filePath)return `<div class="task-head"><div><h2>${task.title}</h2><p>${task.sub}</p></div><span class="task-state">${task.diff?'Diff':'Read only'}</span></div><p class="file-context">${task.filePath}</p><pre class="code-sample ${task.diff?'diff-sample':''}">${task.diff?'<span class="diff-remove">− return home</span>\n<span class="diff-add">+ return invitation.destination</span>\n\nKeep the requested workspace through sign-in.':`# ${task.title}\n\nSample content from ${task.filePath}.\n\nThis file is read only in the prototype.`}</pre>`;
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
function swipeRow(kind,workspace,id,content,label){
  return `<div class="swipe-row swipe-${kind}" data-swipe-kind="${kind}" data-swipe-workspace="${workspace}" data-swipe-id="${id}"><button class="swipe-close" data-swipe-close aria-label="Close ${label}" hidden>Close</button><div class="swipe-content" data-swipe-content>${content}<button class="swipe-reveal" data-swipe-reveal aria-expanded="false" aria-label="Reveal Close for ${label}" title="Swipe left or reveal Close"><svg viewBox="0 0 20 20" aria-hidden="true"><path d="m12 5-5 5 5 5"/></svg></button></div></div>`;
}
function emptyWorkspaceMarkup(){return '<div class="empty-workspaces"><p>No open workspaces.</p><button class="inline-link" data-resume-workspace>Resume Workspace</button></div>'}
function explorerWorkMarkup(el){
  const s=state.get(el);
  const openWorkspaces=workspaces.filter(workspace=>!s.closedWorkspaces.includes(workspace));
  if(!openWorkspaces.length)return emptyWorkspaceMarkup();
  return openWorkspaces.map(workspace=>{
    const current=workspace===s.workspace,closedIds=s.closedTabs[workspace]||[],open=allTasksFor(el,workspace).filter(task=>task.kind!=='home'&&!closedIds.includes(task.id));
    const row=task=>swipeRow('task',workspace,task.id,`<button class="work-row ${current&&task.id===s.selected?'selected':''}" data-pick="${task.id}" data-pick-workspace="${workspace}" aria-current="${current&&task.id===s.selected?'page':'false'}">${icon(task.kind==='chat'?'circusClown':task.kind==='terminal'?'circusTerminal':'circusTicket')}<span class="row-main"><strong>${task.title}</strong></span></button>`,task.title+' tab in '+workspace);
    const heading=`<button class="explorer-workspace-button" data-workspace="${workspace}" aria-current="${current?'page':'false'}">${icon('circusTent')}<span class="row-main"><strong>${workspace}</strong><small>${workspacePaths[workspace]}</small></span>${current?'<span class="workspace-current" aria-label="Current workspace">✓</span>':''}</button>`;
    return `<section class="explorer-group ${current?'current-workspace':''}" aria-label="${workspace}">${swipeRow('workspace',workspace,'',heading,workspace+' workspace')}<div class="workspace-open-tasks">${open.length?open.map(row).join(''):'<p class="workspace-no-tasks">No open tasks</p>'}</div></section>`;
  }).join('');
}
function revealSwipe(el,row,open,focus=false){
  el.querySelectorAll('.swipe-row').forEach(other=>{
    if(other!==row||!open){other.classList.remove('revealed');other.querySelector('[data-swipe-content]').style.transform='';other.querySelector('[data-swipe-close]').hidden=true;other.querySelector('[data-swipe-reveal]').setAttribute('aria-expanded','false')}
  });
  if(open){row.classList.add('revealed');row.querySelector('[data-swipe-content]').style.transform='translateX(-72px)';row.querySelector('[data-swipe-close]').hidden=false;row.querySelector('[data-swipe-reveal]').setAttribute('aria-expanded','true')}
  if(focus)(open?row.querySelector('[data-swipe-close]'):row.querySelector('[data-swipe-content] button')).focus({preventScroll:true});
}
function closeWorkspace(el,workspace){
  const s=state.get(el);s.closedWorkspaces=[...new Set([...s.closedWorkspaces,workspace])];
  if(s.workspace===workspace){s.workspace=workspaces.find(name=>!s.closedWorkspaces.includes(name))||null;s.selected='home';draw(el)}
  renderExplorer(el);(el.querySelector('[data-workspace]')||el.querySelector('[data-resume-workspace]')).focus({preventScroll:true});
}
function explorerFilesMarkup(el){
  if(!state.get(el).workspace)return emptyWorkspaceMarkup();
  const s=state.get(el),data=workspaceData[s.workspace];
  return `<div class="explorer-context"><h2>${s.workspace}</h2><p>${s.workspace==='Solo chats'?'Local notes':'Project files'}</p></div><div class="file-explorer-tree">${Object.entries(data.folders).map(([folder,files])=>{const expanded=!!s.expandedFolders[s.workspace+':'+folder];return `<div><button class="tree-row folder-row" data-tree-toggle="${folder}" aria-expanded="${expanded}"><span class="tree-chevron" aria-hidden="true">${expanded?'⌄':'›'}</span>${icon('files')}<span>${folder}</span></button>${expanded?`<div class="tree-children">${files.map(file=>`<button class="tree-row" data-open-file="${folder}/${file}"><span class="file-glyph" aria-hidden="true">${icon('files')}</span><span>${file}</span></button>`).join('')}</div>`:''}</div>`}).join('')}${data.files.map(file=>`<button class="tree-row" data-open-file="${file}">${icon('files')}<span>${file}</span></button>`).join('')}</div>`;
}
function explorerGitMarkup(el){const workspace=state.get(el).workspace;return workspace?GitPrototype.render(workspace):emptyWorkspaceMarkup();}
function explorerSessionsMarkup(el){const s=state.get(el);if(!s.workspace)return emptyWorkspaceMarkup();return `<div class="explorer-context"><h2>Past sessions</h2><p>${s.workspace}</p></div><div class="session-list">${workspaceData[s.workspace].sessions.map(session=>`<button class="work-row" data-session="${session.id}"><span class="row-main"><strong>${session.title}</strong><small>${s.workspace} · ${session.when}</small></span><span aria-hidden="true">›</span></button>`).join('')}</div>`}
function openSession(el,id){const s=state.get(el),session=workspaceData[s.workspace].sessions.find(item=>item.id===id);if(!session)return;if(!allTasksFor(el).some(task=>task.id===id))(s.extraTabs[s.workspace]||=[]).push({id,title:session.title,kind:'chat',sub:s.workspace+' · past session · '+session.when});setTask(el,id)}
function renderExplorer(el){
  const s=state.get(el),explorer=el.querySelector('[data-explorer]');
  explorer.innerHTML=`<div class="explorer-tabs" role="tablist" aria-label="Explorer views">${[['workspaces','Workspaces'],['git','Git'],['files','Files'],['sessions','Sessions']].map(([id,label])=>`<button type="button" id="explorer-${id}-${s.uid}" role="tab" aria-selected="${s.explorerPane===id}" aria-controls="explorer-pane-${s.uid}" data-explorer-tab="${id}">${label}</button>`).join('')}</div><div class="explorer-pane" id="explorer-pane-${s.uid}" role="tabpanel" aria-labelledby="explorer-${s.explorerPane}-${s.uid}">${s.explorerPane==='workspaces'?`<div class="work-list">${explorerWorkMarkup(el)}</div>`:s.explorerPane==='files'?explorerFilesMarkup(el):s.explorerPane==='sessions'?explorerSessionsMarkup(el):explorerGitMarkup(el)}</div>`;
  const search=explorer.querySelector('input');if(search)search.value=s.search;
}
function openFile(el,path,diff=false){
  const s=state.get(el),id=(diff?'diff:':'file:')+path;
  if(!allTasksFor(el).some(task=>task.id===id))(s.extraTabs[s.workspace]||=[]).push({id,title:(diff?'Diff · ':'')+path.split('/').at(-1),kind:'file',sub:s.workspace+' · '+(diff?'uncommitted changes':'read-only file'),filePath:path,diff});
  setTask(el,id);
}
function closeTab(el,id,workspace=state.get(el).workspace){
  if(workspace!==state.get(el).workspace){
    const s=state.get(el);s.closedTabs[workspace]=[...new Set([...(s.closedTabs[workspace]||[]),id])];renderExplorer(el);el.querySelector(`[data-workspace="${workspace}"]`).focus({preventScroll:true});return;
  }
  if(id==='home')return;const s=state.get(el),keepOpen=s.explorerOpen,keepMenu=s.taskMenuOpen,before=tabsFor(el),index=before.findIndex(task=>task.id===id);
  s.closedTabs[s.workspace]=[...new Set([...(s.closedTabs[s.workspace]||[]),id])];
  const next=s.selected===id?(before[index+1]||before[index-1]||{id:'home'}).id:s.selected;
  if(keepMenu){s.selected=next;draw(el);renderTaskMenu(el);el.querySelector('[data-task-menu-panel] button').focus({preventScroll:true})}
  else if(keepOpen){s.selected=next;draw(el);renderExplorer(el);el.querySelector('[data-explorer-tab="workspaces"]').focus({preventScroll:true})}else setTask(el,next);
}
function closeOtherTabs(el){const s=state.get(el),keepOpen=s.explorerOpen;s.closedTabs[s.workspace]=allTasksFor(el).filter(task=>task.id!=='home'&&task.id!==s.selected).map(task=>task.id);if(s.taskMenuOpen){draw(el);renderTaskMenu(el);el.querySelector('[data-task-menu-panel] button').focus({preventScroll:true})}else if(keepOpen){draw(el);renderExplorer(el);el.querySelector('[data-explorer-tab="workspaces"]').focus({preventScroll:true})}else setTask(el,s.selected)}
function openWork(el,trigger){
  renderExplorer(el);setPanelOpen(el,'left',true,false);
}
function setPanelOpen(el,side,open,restoreFocus=true){
  const s=state.get(el),panels={left:el.querySelector('[data-explorer]'),right:el.querySelector('[data-settings-panel]')},panel=panels[side],view=el.querySelector('[data-view]');
  const edge=side==='left'?'translateX(-100%)':'translateX(100%)';
  const start=panel.hidden?edge:getComputedStyle(panel).transform;
  const epoch=++s.panelEpoch;s.panelAnimation?.cancel();s.panelAnimation=null;
  for(const [other,node] of Object.entries(panels))if(other!==side){node.hidden=true;node.inert=true;node.style.transform=other==='left'?'translateX(-100%)':'translateX(100%)'}
  s.panelSide=side;s.explorerOpen=open&&side==='left';s.settingsOpen=open&&side==='right';
  panel.hidden=false;panel.inert=!open;view.hidden=false;view.inert=true;view.setAttribute('aria-hidden','true');
  const left=el.querySelector('[data-open-work]'),right=el.querySelector('[data-open-settings]');left.setAttribute('aria-expanded',String(s.explorerOpen));right.setAttribute('aria-expanded',String(s.settingsOpen));
  left.setAttribute('aria-label',s.explorerOpen?'Close workspace explorer':'Open workspace explorer');right.setAttribute('aria-label',s.settingsOpen?'Close Settings':'Open Settings');
  const end=open?'translateX(0)':edge;
  const finish=()=>{if(epoch!==s.panelEpoch)return;panel.style.transform=end;panel.hidden=!open;view.inert=open;view.setAttribute('aria-hidden',String(open));s.panelAnimation=null;if(!open)s.panelSide=null};
  if(matchMedia('(prefers-reduced-motion: reduce)').matches||!panel.animate)finish();
  else{const animation=panel.animate([{transform:start},{transform:end}],{duration:180,easing:'ease-out',fill:'forwards'});s.panelAnimation=animation;animation.finished.then(()=>{finish();animation.cancel()}).catch(()=>{})}
  if(!open&&restoreFocus)(side==='left'?left:right).focus({preventScroll:true});
}
function openSettings(el){state.get(el).settingsCategory=null;renderSettings(el);setPanelOpen(el,'right',true,false)}
function renderSettings(el){
  const s=state.get(el),category=s.settingsCategory,panel=el.querySelector('[data-settings-panel]');
  const back=category?'<button class="settings-back" data-settings-back>‹ Settings</button>':'';
  const body=!category?`<div class="settings-categories">${['Connection','Security','Notifications','Appearance'].map(name=>`<button class="list-action" data-setting-category="${name}"><span>${name}</span><span class="chev" aria-hidden="true">›</span></button>`).join('')}</div><button class="list-action" data-settings-home>Go to Home</button>`:category==='Appearance'?`<p>Choose the preview appearance.</p><div class="appearance-options"><button data-appearance="light" aria-pressed="${!document.body.classList.contains('dark')}">Paper</button><button data-appearance="dark" aria-pressed="${document.body.classList.contains('dark')}">Slate</button></div>`:category==='Connection'?'<p>Sample host: Local Mac.</p><p>This preview does not connect to a host.</p>':`<button class="list-action" data-settings-toggle="${category}" aria-pressed="${!!s.sampleSettings[category]}"><span>${category==='Security'?'App lock':'Allow notifications'}</span><span class="setting-value">${s.sampleSettings[category]?'On':'Off'}</span></button><p class="settings-note">Sample setting for this preview only.</p>`;
  panel.innerHTML=`<div class="settings-pane">${back}<h2>${category||'Settings'}</h2><p class="settings-context">This device</p>${body}</div>`;
}
function renderTaskMenu(el){
  const s=state.get(el),panel=el.querySelector('[data-task-menu-panel]');
  panel.setAttribute('aria-label',`Switch task in ${s.workspace}`);
  panel.innerHTML=`${tabsFor(el).map(task=>`<button class="manager-select" role="menuitem" data-tab="${task.id}" aria-current="${task.id===s.selected?'page':'false'}"><strong>${task.title}</strong></button>`).join('')}`;
}
function openTaskMenu(el){
  const s=state.get(el);if(s.taskMenuOpen){closeTaskMenu(el);return}
  renderTaskMenu(el);s.taskMenuOpen=true;el.querySelector('[data-task-menu-panel]').hidden=false;
  el.querySelector('[data-task-menu]').setAttribute('aria-expanded','true');
  const panel=el.querySelector('[data-task-menu-panel]');(panel.querySelector('[aria-current="page"]')||panel.querySelector('button')).focus({preventScroll:true});
}
function closeTaskMenu(el,restoreFocus=true){
  const s=state.get(el);if(!s.taskMenuOpen)return;s.taskMenuOpen=false;
  el.querySelector('[data-task-menu-panel]').hidden=true;el.querySelector('[data-task-menu]').setAttribute('aria-expanded','false');
  if(restoreFocus)el.querySelector('[data-task-menu]').focus({preventScroll:true});
}
function workMarkup(el){
  const s=state.get(el), q=s.search.trim().toLowerCase();
  const groups=[{label:s.workspace==='Solo chats'?'Standalone chats':s.workspace,items:tabsFor(el)},...workspaces.filter(w=>w!==s.workspace).map(w=>({label:w,items:[...tasksByWorkspace[w],...(s.extraTabs[w]||[])].filter(t=>t.kind!=='home')}))];
  const matched=groups.map(g=>({...g,items:g.items.filter(t=>`${t.title} ${t.sub} ${g.label}`.toLowerCase().includes(q))})).filter(g=>g.items.length);
  if(!matched.length)return '<p class="empty-search">No matching work. Try a task or workspace name.</p>';
  return matched.map(g=>`<section><h3 class="work-group-title">${g.label}</h3>${g.items.map(t=>{const workspace=g.label==='Standalone chats'?'Solo chats':g.label,selected=workspace===s.workspace&&t.id===s.selected;return `<button class="work-row ${selected?'selected':''}" data-pick="${t.id}" data-pick-workspace="${workspace}" aria-current="${selected?'page':'false'}"><span class="row-mark" aria-hidden="true"></span><span class="row-main"><strong>${t.title}</strong><small>${t.sub}</small></span><span aria-hidden="true">${selected?'✓':'›'}</span></button>`}).join('')}</section>`).join('');
}
function closeWork(el,restoreFocus=true){
  const s=state.get(el),layer=el.querySelector('[data-sheet]');
  if(s.panelSide)setPanelOpen(el,s.panelSide,false,restoreFocus);
  if(layer.hidden)return;
  layer.hidden=true;[...el.querySelector('[data-screen]').children].forEach(child=>child.inert=false);
  el.querySelectorAll('[data-open-work],[data-task-menu]').forEach(b=>b.setAttribute('aria-expanded','false'));
  if(restoreFocus)(s.returnFocus?.isConnected&&!s.returnFocus.hidden?s.returnFocus:el.querySelector('[data-open-work]')).focus({preventScroll:true});
  s.sheetKind=null;s.returnFocus=null;
}
function setTask(el,id){
  const s=state.get(el),destinations={newchat:{id:'newchat',title:'New Chat',kind:'chat',sub:`${s.workspace} · new conversation`,workspace:s.workspace},newterminal:{id:'newterminal',title:'Terminal · new',kind:'terminal',sub:`${s.workspace} · sample shell`},files:{id:'files',title:'Files',kind:'file',sub:`${s.workspace} · project files`},settings:{id:'settings',title:'Settings',kind:'settings',sub:'AgentLand on this device'}};
  if(destinations[id]&&!allTasksFor(el).some(t=>t.id===id))(s.extraTabs[s.workspace]||=([])).push(destinations[id]);
  s.closedTabs[s.workspace]=(s.closedTabs[s.workspace]||[]).filter(closed=>closed!==id);
  s.selected=id;if(id!=='home')s.lastTaskByWorkspace[s.workspace]=id;closeTaskMenu(el,false);closeWork(el,false);draw(el);el.querySelector('[data-task-menu]').focus({preventScroll:true});
}
function action(el,name,trigger){
  const s=state.get(el);
  if(!s.workspace&&['New Chat','New Terminal'].includes(name)){s.pendingHomeAction=name;changeHomeMenu(el,'Resume Workspace');return}
  if(actions.some(item=>item.name===name)&&el.querySelector('[data-home-actions]')){changeHomeMenu(el,name);return}
  if(name==='New Chat')setTask(el,'newchat');
  else if(name==='New Terminal')setTask(el,'newterminal');
  else if(name==='Browse Files'){s.explorerPane='files';openWork(el,trigger);}
  else if(name==='Resume Work'){const recent=tabsFor(el).find(task=>task.kind==='chat');if(recent)setTask(el,recent.id);else openWork(el)}
  else if(name==='Open Workspace'){s.explorerPane='workspaces';openWork(el,trigger);}
  else if(name==='Settings')openSettings(el);
}
document.querySelectorAll('[data-concept]').forEach((el,index)=>{
  state.set(el,{uid:`${index+1}`,workspace:'AgentLand',selected:'home',search:'',extraTabs:{},closedTabs:{},explorerOpen:false,settingsOpen:false,panelSide:null,panelAnimation:null,panelEpoch:0,explorerPane:'workspaces',expandedFolders:{},settingsCategory:null,sampleSettings:{},closedWorkspaces:[],swipeGesture:null,suppressSwipeClickUntil:0,pendingHomeAction:null,returnFocus:null,sheetKind:null,homeMenu:null,homeOriginAction:null,homeAnimations:[],homeEpoch:0,homeTileRect:null,taskMenuOpen:false,lastTaskByWorkspace:{AgentLand:'signin','Website refresh':'hero','Solo chats':'draft'}});
  draw(el);
  el.addEventListener('pointerdown',event=>{
    const row=event.target.closest('.swipe-row');if(!row||event.button!==0||event.target.closest('[data-swipe-close]'))return;
    state.get(el).swipeGesture={row,x:event.clientX,y:event.clientY,offset:row.classList.contains('revealed')?-72:0,dragging:false,pointerId:event.pointerId};
  });
  el.addEventListener('pointermove',event=>{
    const s=state.get(el),gesture=s.swipeGesture;if(!gesture||gesture.pointerId!==event.pointerId)return;
    const dx=event.clientX-gesture.x,dy=event.clientY-gesture.y;
    if(!gesture.dragging){
      if(Math.abs(dy)>12&&Math.abs(dy)>Math.abs(dx)){s.swipeGesture=null;return}
      if(Math.abs(dx)<12||Math.abs(dx)<Math.abs(dy)*1.2)return;
      gesture.dragging=true;revealSwipe(el,gesture.row,true);gesture.row.setPointerCapture(event.pointerId);
    }
    event.preventDefault();gesture.row.querySelector('[data-swipe-content]').style.transform=`translateX(${Math.max(-72,Math.min(0,gesture.offset+dx))}px)`;
  });
  const finishSwipe=event=>{
    const s=state.get(el),gesture=s.swipeGesture;if(!gesture||gesture.pointerId!==event.pointerId)return;
    if(gesture.dragging){const open=event.type!=='pointercancel'&&gesture.offset+event.clientX-gesture.x < -28;revealSwipe(el,gesture.row,open);s.suppressSwipeClickUntil=performance.now()+350}
    s.swipeGesture=null;
  };
  el.addEventListener('pointerup',finishSwipe);el.addEventListener('pointercancel',finishSwipe);
  el.addEventListener('contextmenu',event=>{const row=event.target.closest('.swipe-row');if(row){event.preventDefault();revealSwipe(el,row,true,true)}});
  el.addEventListener('click',event=>{
    if(event.target===el.querySelector('[data-sheet]')){closeWork(el);return}
    const t=event.target.closest('button');if(!t)return;
    if(t.matches('[data-git-action]')){const s=state.get(el),scroll=el.querySelector('.explorer-pane').scrollTop;GitPrototype.run(s.workspace,t.dataset.gitAction,t.dataset.gitKey);renderExplorer(el);el.querySelector('.explorer-pane').scrollTop=scroll;if(GitPrototype.repository(s.workspace).confirm)el.querySelector('[data-git-action="cancel"]').focus();else ([...el.querySelectorAll("[data-git-action]")].find(button=>button.dataset.gitAction===t.dataset.gitAction&&button.dataset.gitKey===t.dataset.gitKey)||el.querySelector("[data-git-action]")).focus({preventScroll:true});return;}
    if(t.closest('.swipe-row')&&!t.matches('[data-swipe-close]')&&performance.now()<state.get(el).suppressSwipeClickUntil){event.preventDefault();return}
    if(t.matches('[data-swipe-reveal]')){const row=t.closest('.swipe-row');revealSwipe(el,row,!row.classList.contains('revealed'),true);return}
    if(t.matches('[data-swipe-close]')){const row=t.closest('.swipe-row');if(!row.classList.contains('revealed'))return;if(row.dataset.swipeKind==='workspace')closeWorkspace(el,row.dataset.swipeWorkspace);else closeTab(el,row.dataset.swipeId,row.dataset.swipeWorkspace);return}
    if(t.matches('[data-resume-workspace]')){setTask(el,'home');changeHomeMenu(el,'Resume Workspace');return}
    if(t.matches('[data-home-back]')){state.get(el).pendingHomeAction=null;changeHomeMenu(el,null);return}
    if(t.matches('[data-home-choice]')){chooseHomeOption(el,t.dataset.homeChoice);return}
    if(t.matches('[data-open-work]')){if(state.get(el).explorerOpen)closeWork(el);else openWork(el,t);return}
    if(t.matches('[data-open-settings]')){if(state.get(el).settingsOpen)closeWork(el);else openSettings(el);return}
    if(t.matches('[data-setting-category]')){state.get(el).settingsCategory=t.dataset.settingCategory;renderSettings(el);return}
    if(t.matches('[data-settings-back]')){state.get(el).settingsCategory=null;renderSettings(el);return}
    if(t.matches('[data-settings-home]')){setTask(el,'home');return}
    if(t.matches('[data-settings-toggle]')){const s=state.get(el),key=t.dataset.settingsToggle;s.sampleSettings[key]=!s.sampleSettings[key];renderSettings(el);return}
    if(t.matches('[data-appearance]')){const dark=t.dataset.appearance==='dark';if(document.body.classList.contains('dark')!==dark)document.querySelector('.theme-toggle').click();renderSettings(el);return}
    if(t.matches('[data-explorer-tab]')){const s=state.get(el);s.explorerPane=t.dataset.explorerTab;renderExplorer(el);el.querySelector(`[data-explorer-tab="${s.explorerPane}"]`).focus({preventScroll:true});return}
    if(t.matches('[data-tree-toggle]')){const s=state.get(el),key=s.workspace+':'+t.dataset.treeToggle;s.expandedFolders[key]=!s.expandedFolders[key];renderExplorer(el);el.querySelector(`[data-tree-toggle="${t.dataset.treeToggle}"]`)?.focus({preventScroll:true});return}
    if(t.matches('[data-open-file]')){openFile(el,t.dataset.openFile,t.hasAttribute('data-diff'));return}
    if(t.matches('[data-session]')){openSession(el,t.dataset.session);return}
    if(t.matches('[data-close-tab]')){closeTab(el,t.dataset.closeTab,t.dataset.closeWorkspace);return}
    if(t.matches('[data-close-other-tabs]')){closeOtherTabs(el);return}
    if(t.matches('[data-show-in-explorer]')){state.get(el).explorerPane='workspaces';openWork(el);return}
    if(t.matches('[data-task-menu]')){openTaskMenu(el,t);return}
    if(t.matches('[data-close-sheet]')){closeWork(el);return}
    if(t.matches('[data-workspace]')){const s=state.get(el);s.workspace=t.dataset.workspace;s.selected='home';draw(el);renderExplorer(el);[...el.querySelectorAll('[data-workspace]')].find(button=>button.dataset.workspace===s.workspace)?.focus({preventScroll:true});return}
    if(t.matches('[data-pick]')){const s=state.get(el);s.workspace=t.dataset.pickWorkspace;setTask(el,t.dataset.pick);return}
    if(t.matches('[data-tab]')){setTask(el,t.dataset.tab);return}
    if(t.matches('[data-action]')){action(el,t.dataset.action,t);return}
    if(t.matches('[data-toggle-theme]'))document.querySelector('.theme-toggle').click();
    if(t.matches('[data-file]')){const title=t.dataset.file;el.querySelector('.file-card').innerHTML=`<strong>Selected · ${title}</strong><p>${title==='README.md'?'# AgentLand\nA shared workspace for active work.':`Sample ${title.toLowerCase()} content`}</p><button class="inline-link" data-action="Resume Work">Return to recent work</button>`;return}
    if(t.matches('[data-setting]')){const title=t.dataset.setting;const card=el.querySelector('.file-card');if(card)card.innerHTML=`<strong>${title}</strong><p>Sample ${title.toLowerCase()} settings are shown in this prototype.</p><button class="inline-link" data-toggle-theme>Compare appearance</button>`;return}
    if(t.matches('.send-button')){const composer=t.closest('.composer');composer.innerHTML='<span>Sample message ready to send</span><button class="send-button" aria-label="Return to Home" data-tab="home">✓</button>';return}
  });
  el.addEventListener('input',event=>{if(event.target.matches('[data-git-field]')){GitPrototype.input(state.get(el).workspace,event.target.dataset.gitField,event.target.value);return;}if(event.target.matches('.sheet-search')){const s=state.get(el);s.search=event.target.value;const list=el.querySelector('.work-list');list.innerHTML=explorerWorkMarkup(el)}});
  el.addEventListener('keydown',event=>{
    const swipe=event.target.closest('.swipe-row');
    if(swipe&&event.key==='ArrowLeft'){event.preventDefault();revealSwipe(el,swipe,true,true);return}
    if(swipe&&['Escape','ArrowRight'].includes(event.key)&&swipe.classList.contains('revealed')){event.preventDefault();revealSwipe(el,swipe,false,true);return}
    if(state.get(el).taskMenuOpen){
      if(event.key==='Escape'){event.preventDefault();closeTaskMenu(el);return}
      if(event.target.closest('[data-task-menu-panel]')&&['ArrowDown','ArrowUp','Home','End'].includes(event.key)){
        event.preventDefault();const controls=[...el.querySelectorAll('[data-task-menu-panel] button')],index=controls.indexOf(document.activeElement);
        controls[event.key==='Home'?0:event.key==='End'?controls.length-1:(index+(event.key==='ArrowDown'?1:controls.length-1))%controls.length].focus();return;
      }
      if(event.key==='Tab')closeTaskMenu(el,false);
    }
    if(event.target.matches('[data-explorer-tab]')&&['ArrowLeft','ArrowRight'].includes(event.key)){event.preventDefault();const s=state.get(el),panes=['workspaces','git','files','sessions'];s.explorerPane=panes[(panes.indexOf(s.explorerPane)+(event.key==='ArrowRight'?1:3))%4];renderExplorer(el);el.querySelector(`[data-explorer-tab="${s.explorerPane}"]`).focus({preventScroll:true});return}
    const layer=el.querySelector('[data-sheet]');if(layer.hidden){if(event.key==='Escape'){const s=state.get(el);if(s.panelSide){event.preventDefault();closeWork(el)}else if(s.homeMenu){event.preventDefault();changeHomeMenu(el,null)}}return}
    if(event.key==='Escape'){event.preventDefault();closeWork(el);return}
    if(event.key==='Tab'){
      const controls=[...layer.querySelectorAll('button,input')].filter(control=>!control.hidden),first=controls[0],last=controls.at(-1);
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}
    }
  });
});
document.addEventListener('click',event=>{
  const fromTaskMenu=event.composedPath().some(node=>node.matches?.('[data-task-menu],[data-task-menu-panel]'));
  document.querySelectorAll('[data-concept]').forEach(el=>{if(state.get(el).taskMenuOpen&&!fromTaskMenu)closeTaskMenu(el,false)});
  const tone=event.target.closest('.tone-toggle');
  if(tone){const original=document.body.classList.toggle('original-art');tone.setAttribute('aria-pressed',String(!original));tone.setAttribute('aria-label',original?'Soften artwork tones':'Show original artwork tones');tone.textContent=original?'Soften artwork tones':'Show original tones';return}
  const theme=event.target.closest('.theme-toggle');if(theme){const dark=document.body.classList.toggle('dark');theme.setAttribute('aria-pressed',String(dark));theme.setAttribute('aria-label',dark?'Switch to light appearance':'Switch to dark appearance');theme.querySelector('.theme-label').textContent=dark?'Light appearance':'Dark appearance';document.querySelectorAll('[data-concept]').forEach(el=>{if(state.get(el).settingsOpen)renderSettings(el)});return}
});
