(function(root){
  'use strict';
  const repositories=new Map();
  const copy=value=>JSON.parse(JSON.stringify(value));
  const escape=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  function fixtures(workspace){
    if(workspace==='AgentLand')return [
      {path:'Sources/LoginRouter.swift',status:'modified',staged:false,before:'func resumeInvitation() {\n    route = .home\n}',after:'func resumeInvitation() {\n    route = invitation.destination\n    keepWorkspaceSelection()\n}'},
      {path:'docs/README.md',status:'modified',staged:true,before:'# AgentLand\n\nMobile workspace.',after:'# AgentLand\n\nMobile workspace.\nKeep the invitation destination through sign-in.'},
      {path:'Tests/WorkspaceTests.swift',status:'untracked',staged:false,before:'',after:'func testInvitationDestination() {\n    XCTAssertEqual(route, invitation.destination)\n}'}
    ];
    if(workspace==='Website refresh')return [
      {path:'src/index.html',status:'modified',staged:false,before:'<h1>Website refresh</h1>\n<p>Project notes</p>',after:'<h1>Project notes</h1>\n<p>Changes to the website</p>'},
      {path:'src/tokens.css',status:'modified',staged:true,before:':root {\n  --space: 12px;\n}',after:':root {\n  --space: 16px;\n}'},
      {path:'docs/content-notes.md',status:'untracked',staged:false,before:'',after:'# Content notes\n\nUse specific action labels.'}
    ];
    return (workspace==='Solo chats'?['release-notes.md','meeting-notes.md']:['README.md']).map(path=>({path,status:'untracked',staged:false,before:'',after:'# '+path.replace('.md','')+'\n\nSample workspace notes.'}));
  }
  function repository(workspace){
    if(repositories.has(workspace))return repositories.get(workspace);
    const files=fixtures(workspace),initialized=['AgentLand','Website refresh'].includes(workspace);
    const tracked=Object.fromEntries(files.filter(file=>file.status!=='untracked').map(file=>[file.path,file.before]));
    const seedPath=workspace==='Website refresh'?'README.md':'docs/README.md';
    const commits={
      '28a7641':{id:'28a7641',parent:null,message:'Add workspace notes',when:'Monday · sample',files:[{path:seedPath,before:'',after:'# '+workspace, status:'added'}]},
      '9fa1832':{id:'9fa1832',parent:'28a7641',message:'Prepare workspace navigation',when:'Yesterday · sample',files:[{path:seedPath,before:'# '+workspace,after:tracked[seedPath]||'# '+workspace+'\n\nMobile workspace.',status:'modified'}]}
    };
    const r={workspace,initialized,branch:'main',branches:{main:{head:initialized?'9fa1832':null,tracking:initialized?'origin/main':null}},remotes:initialized?{origin:{url:'https://example.invalid/'+workspace.toLowerCase().replaceAll(' ','-')+'.git',fetched:false}}:{},remoteRefs:initialized?{'origin/main':'9fa1832','origin/review':'28a7641'}:{},commits,files:initialized?files:[],seedFiles:files,initialFiles:tracked,baseFiles:{...tracked},stashes:[],counter:1,commitMessage:'',branchName:'',stashName:'',notice:'',confirm:null,preview:null,collapsed:new Set(['branches','history','stashes'])};
    repositories.set(workspace,r);return r;
  }
  function history(r,head=r.branches[r.branch].head){const result=[],seen=new Set();while(head&&r.commits[head]&&!seen.has(head)){seen.add(head);const commit=r.commits[head];result.push(commit);head=commit.parent}return result}
  function counts(r){const branch=r.branches[r.branch],local=history(r).map(commit=>commit.id),remote=history(r,r.remoteRefs[branch.tracking]??null).map(commit=>commit.id);return {ahead:local.filter(id=>!remote.includes(id)).length,behind:remote.filter(id=>!local.includes(id)).length,tracking:branch.tracking}}
  function treeAt(r,head){const tree={...r.initialFiles};history(r,head).reverse().forEach(commit=>commit.files.forEach(file=>{tree[file.path]=file.after}));return tree}
  function notify(r,message){r.notice=message;return true}
  function stash(r,name){
    if(!r.files.length)return notify(r,'There are no sample changes to stash.');
    r.stashes.unshift({id:'stash-'+r.counter++,name:name||r.stashName.trim()||'WIP on '+r.branch,branch:r.branch,files:copy(r.files)});
    r.files=[];r.stashName='';return notify(r,'Sample changes stashed, including staged and untracked files.');
  }
  function switchBranch(r,name){
    if(!r.branches[name])return notify(r,'That sample branch is unavailable.');
    if(name===r.branch)return notify(r,'This sample branch is already selected.');
    if(r.files.length){r.confirm={kind:'switch',target:name,title:'Uncommitted changes',detail:'Stash the staged, unstaged and untracked sample changes before switching to '+name+'.',label:'Stash and switch'};return true}
    r.branch=name;r.baseFiles=treeAt(r,r.branches[name].head);r.preview=null;return notify(r,'Switched sample branch to '+name+'.');
  }
  function run(workspace,action,key=''){
    const r=repository(workspace);
    if(r.confirm&&!['confirm','cancel'].includes(action))return false;
    if(action==='cancel'){r.confirm=null;return true}
    if(action==='confirm'){
      const pending=r.confirm;if(!pending)return false;r.confirm=null;
      if(pending.kind==='switch'){stash(r,'Before switching to '+pending.target);return switchBranch(r,pending.target)}
      if(pending.kind==='discard'){r.files=r.files.filter(file=>!pending.paths.includes(file.path));r.preview=null;return notify(r,'Discarded the selected sample changes.')}
      if(pending.kind==='drop'){r.stashes=r.stashes.filter(item=>item.id!==pending.target);return notify(r,'Dropped the sample stash.')}
      if(pending.kind==='delete'){if(pending.target===r.branch)return notify(r,'The current branch cannot be deleted.');delete r.branches[pending.target];return notify(r,'Deleted sample branch '+pending.target+'.')}
    }
    if(action==='toggle'){r.collapsed.has(key)?r.collapsed.delete(key):r.collapsed.add(key);return true}
    if(action==='initialize'){r.initialized=true;r.files=copy(r.seedFiles);r.commits={};r.branches={main:{head:null,tracking:null}};r.branch='main';return notify(r,'Initialized a sample repository. No Git command was run.')}
    if(action==='add-remote'){r.remotes.origin={url:'https://example.invalid/'+workspace.toLowerCase().replaceAll(' ','-')+'.git',fetched:true};return notify(r,'Added a sample origin. No network connection was made.')}
    if(action==='stage'||action==='unstage'){const file=r.files.find(item=>item.path===key);if(!file)return false;file.staged=action==='stage';if(r.preview?.source==='working'&&r.preview.path===file.path)r.preview.staged=file.staged;return notify(r,(file.staged?'Staged':'Unstaged')+' sample file: '+file.path)}
    if(action==='stage-all'||action==='unstage-all'){r.files.forEach(file=>file.staged=action==='stage-all');return notify(r,action==='stage-all'?'All sample changes staged.':'All sample changes unstaged.')}
    if(action==='discard'){const paths=key?[key]:r.files.map(file=>file.path);if(!paths.length)return notify(r,'There are no sample changes to discard.');r.confirm={kind:'discard',paths,title:key?'Discard changes to '+key+'?':'Discard all sample changes?',detail:'This clears the selected changes in this preview. It does not alter any real file.',label:'Discard changes'};return true}
    if(action==='commit'){
      const staged=r.files.filter(file=>file.staged),message=r.commitMessage.trim();
      if(!message)return notify(r,'Enter a commit message.');if(!staged.length)return notify(r,'Stage at least one file before committing.');
      const id='c'+String(r.counter++).padStart(6,'0');
      r.commits[id]={id,parent:r.branches[r.branch].head,message,when:'Now · sample',files:copy(staged)};
      r.branches[r.branch].head=id;staged.forEach(file=>r.baseFiles[file.path]=file.after);r.files=r.files.filter(file=>!file.staged);r.commitMessage='';r.collapsed.delete('history');return notify(r,'Created sample commit '+id+' with '+staged.length+' file'+(staged.length===1?'':'s')+'.');
    }
    if(action==='create-branch'){
      const name=r.branchName.trim();if(!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(name)||name.includes('..')||name.includes('//')||name.endsWith('/')||name.endsWith('.lock'))return notify(r,'Use a branch name without spaces, .., // or a trailing slash.');
      if(r.branches[name])return notify(r,'That sample branch already exists.');r.branches[name]={head:r.branches[r.branch].head,tracking:null};r.branchName='';return notify(r,'Created sample branch '+name+'. Select it to switch.');
    }
    if(action==='switch')return switchBranch(r,key);
    if(action==='checkout-remote'){
      const name=key.slice(key.indexOf('/')+1);if(!r.branches[name])r.branches[name]={head:r.remoteRefs[key],tracking:key};return switchBranch(r,name);
    }
    if(action==='delete-branch'){if(key===r.branch)return notify(r,'Switch away from the current branch before deleting it.');r.confirm={kind:'delete',target:key,title:'Delete sample branch '+key+'?',detail:'Only the sample branch reference is removed. No real repository is changed.',label:'Delete branch'};return true}
    if(action==='stash')return stash(r);
    if(action==='apply-stash'){
      const saved=r.stashes.find(item=>item.id===key);if(!saved)return false;
      if(saved.files.some(file=>r.files.some(local=>local.path===file.path)||(file.status!=='untracked'&&r.baseFiles[file.path]!==file.before)))return notify(r,'The stash overlaps changed sample files. Commit or discard those changes, or return to its original branch.');
      r.files.push(...copy(saved.files));return notify(r,'Applied the sample stash and restored its staged state. The stash is still saved.');
    }
    if(action==='drop-stash'){r.confirm={kind:'drop',target:key,title:'Drop this sample stash?',detail:'Its saved sample changes will be removed from the stash list.',label:'Drop stash'};return true}
    if(action==='fetch'){
      const remote=Object.values(r.remotes)[0];if(!remote)return notify(r,'Add a sample remote first.');
      if(!remote.fetched&&r.remoteRefs['origin/main']){r.commits['31c65f8']={id:'31c65f8',parent:r.remoteRefs['origin/main'],message:'Document workspace handoff',when:'Today · sample remote',files:[{path:'README.md',before:'# '+workspace,after:'# '+workspace+'\n\nWorkspace handoff notes.',status:'modified'}]};r.remoteRefs['origin/main']='31c65f8'}
      remote.fetched=true;return notify(r,'Sample remote references refreshed. No network request was sent.');
    }
    if(action==='pull'){
      const sync=counts(r);if(!sync.tracking)return notify(r,'This sample branch has no upstream. Push to publish it first.');
      if(r.files.length)return notify(r,'Commit, stash or discard sample changes before pulling.');
      if(sync.ahead&&sync.behind)return notify(r,'Sample branches have diverged. This preview supports fast-forward pulls only; no merge was performed.');
      if(!sync.behind)return notify(r,'The sample branch is already up to date.');r.branches[r.branch].head=r.remoteRefs[sync.tracking];r.baseFiles=treeAt(r,r.branches[r.branch].head);return notify(r,'Fast-forwarded the sample branch. No real pull was run.');
    }
    if(action==='push'){
      if(!Object.keys(r.remotes).length)return notify(r,'Add a sample remote first.');if(counts(r).behind)return notify(r,'Fetch and pull the sample remote changes before pushing.');
      if(!r.branches[r.branch].head)return notify(r,'Create a sample commit before pushing.');const ref=r.branches[r.branch].tracking||'origin/'+r.branch;r.remoteRefs[ref]=r.branches[r.branch].head;r.branches[r.branch].tracking=ref;return notify(r,'Published the sample branch to '+ref+'. No real push was run.');
    }
    if(action==='preview'){
      const [source,...parts]=key.split('|'),path=parts.join('|');let file;
      if(source==='working')file=r.files.find(item=>item.path===path);
      else if(source.startsWith('stash:'))file=r.stashes.find(item=>item.id===source.slice(6))?.files.find(item=>item.path===path);
      else file=r.commits[source]?.files.find(item=>item.path===path);
      if(file)r.preview={...copy(file),source};return !!file;
    }
    if(action==='back'){r.preview=null;return true}return false;
  }
  function input(workspace,field,value){if(['commitMessage','branchName','stashName'].includes(field))repository(workspace)[field]=value.slice(0,2000)}
  const api={repository,run,input,history,counts,escape};
  root.GitPrototype=api;
  if(typeof module!=='undefined')module.exports=api;
})(typeof window!=='undefined'?window:globalThis);
