// Local SVG artwork. No third-party font, image, icon, analytics or cloud request.
const icons = {
 home:'<path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1Z"/>',
 wifi:'<path d="M2 8.5a16 16 0 0 1 20 0M5.5 12a10.5 10.5 0 0 1 13 0M9 15.5a5 5 0 0 1 6 0"/><circle cx="12" cy="19" r=".8"/>',
 info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
 refresh:'<path d="M20 7v5h-5M4 17v-5h5"/><path d="M19.3 11A7.5 7.5 0 0 0 6 6.5L4 9M4.7 13A7.5 7.5 0 0 0 18 17.5l2-2.5"/>',
 power:'<path d="M12 3v9M7 5.5a8 8 0 1 0 10 0"/>',
 minus:'<path d="M5 12h14"/>',plus:'<path d="M5 12h14M12 5v14"/>',
 thermometer:'<path d="M9 14.5V5a3 3 0 0 1 6 0v9.5a5 5 0 1 1-6 0Z"/><path d="M12 8v10"/><circle cx="12" cy="18" r="1"/>',
 outdoor:'<path d="M8 17H5a3 3 0 0 1 0-6h.2A5.5 5.5 0 0 1 16 9.5"/><path d="M17 12v5.5a3 3 0 1 0 4 0V12a2 2 0 0 0-4 0Z"/>',
 cool:'<path d="M12 2v20M3.3 7l17.4 10M3.3 17 20.7 7M8.5 4.5 12 7l3.5-2.5M8.5 19.5 12 17l3.5 2.5M3.5 11l4-1.3.4-4.2M20.5 13l-4 1.3-.4 4.2M3.5 13l4 1.3.4 4.2M20.5 11l-4-1.3-.4-4.2"/>',
 heat:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.4 1.4M17.6 17.6 19 19M5 19l1.4-1.4M17.6 6.4 19 5"/>',
 auto:'<path d="m7 15 5-10 5 10M9 12h6M4 7A9 9 0 0 1 20 8M20 4v4h-4M20 17A9 9 0 0 1 4 16M4 20v-4h4"/>',
 dry:'<path d="M12 2C10 6 5 11 5 15a7 7 0 0 0 14 0c0-4-5-9-7-13Z"/><path d="M8 15a4 4 0 0 0 4 4"/>',
 fan:'<circle cx="12" cy="12" r="2"/><path d="M10 10C3 6 9 0 12 4c1 2 0 4 0 6M14 10c4-7 10-1 6 2-2 1-4 0-6 0M14 14c7 4 1 10-2 6-1-2 0-4 0-6M10 14c-4 7-10 1-6-2 2-1 4 0 6 0"/>',
 airflow:'<path d="M3 7h13a3 3 0 1 0-3-3M3 12h16a3 3 0 1 1-3 3M3 17h6a3 3 0 1 1-3 3"/>',
 check:'<path d="m5 12 4 4L19 6"/>',shield:'<path d="M12 2 3 6v6c0 6 9 10 9 10s9-4 9-10V6Z"/><path d="m8 12 3 3 5-6"/>',
 search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',close:'<path d="m6 6 12 12M6 18 18 6"/>',
 room:'<path d="M4 21V4l11-2v19M4 21h16V6h-5M11 12h.01"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.room}</svg>`;
document.querySelectorAll('[data-icon]').forEach(el => {el.innerHTML = icon(el.dataset.icon);});
const $ = id => document.getElementById(id);
const modes = [{id:'cool',label:'Froid'},{id:'heat',label:'Chaud'},{id:'auto',label:'Auto'},{id:'dry',label:'Déshum.'},{id:'fan',label:'Ventilation'}];
// Server observations stay separate from the user's unsent draft. Only the room id
// is persisted. No temperature, credential or response body goes into localStorage.
const state = {session:null,devices:[],selected:null,draft:null,dirty:false,busy:false,refreshing:false,notice:'',mode:'live',lastStatus:'',statusType:''};
try {state.selected = localStorage.getItem('daikin-selected-room');} catch {}
const modeLabel = value => modes.find(m => m.id === value)?.label || 'Mode inconnu';
const temperature = value => typeof value === 'number' && Number.isFinite(value) ? value.toLocaleString('fr-FR',{maximumFractionDigits:1}) : '—';
const selectedDevice = () => state.devices.find(d => d.id === state.selected);
const temperatureAvailable = () => !!selectedDevice()?.capabilities?.temperature && !['dry','fan'].includes(state.draft?.mode);
const limitsForDraft = () => {
 const d=selectedDevice();const mode=state.draft?.mode;
 const ranges={cool:{min:18,max:32,step:.5},heat:{min:10,max:30,step:.5},auto:{min:18,max:30,step:.5}};
 return d?.modeLimits?.[mode]||(d?.mode===mode&&d?.limits?d.limits:ranges[mode])||{min:18,max:32,step:.5};
};
const writable = () => !!state.session?.writesEnabled && !!selectedDevice()?.online && !state.busy && !state.refreshing;
function message(text,type='') {state.lastStatus=text;state.statusType=type;renderControls();}
// All mutations require the session CSRF token. A failed request never implies
// that the physical unit accepted a command: the last observation stays visible.
async function request(path,{method='GET',body}={}) {
 const controller=new AbortController(); const timer=setTimeout(()=>controller.abort(),20000);
 try {
  const headers={Accept:'application/json'};
  if(method!=='GET'){if(!state.session?.csrfToken)throw new Error('La connexion à l’application doit être rétablie. Actualisez la page.');headers['Content-Type']='application/json';headers['X-CSRF-Token']=state.session.csrfToken;}
  const response=await fetch(path,{method,headers,body:body===undefined?undefined:JSON.stringify(body),signal:controller.signal,cache:'no-store'});
  const data=await response.json().catch(()=>null);
  if(!response.ok)throw new Error(data?.error || 'La connexion n’a pas abouti. Réessayez dans un instant.');
  if(!data)throw new Error('La réponse de la connexion est illisible.');
  return data;
 } catch(error){if(error.name==='AbortError')throw new Error('Le climatiseur met trop de temps à répondre. Vérifiez votre réseau puis actualisez.');if(error instanceof TypeError)throw new Error('Le serveur local est inaccessible. Vérifiez qu’il est toujours ouvert.');throw error;}
 finally {clearTimeout(timer);}
}
function resetDraft(){const d=selectedDevice();state.draft=d?{mode:d.mode,target:d.target,fan:d.fan,swing:d.swing}:null;state.dirty=false;}
// Preserve the last readable values if a later observation reports a unit offline.
function ingest(data){
 const previous=new Map(state.devices.map(d=>[d.id,d]));
 state.devices=(data.devices||[]).map(d=>d.online?d:{...previous.get(d.id),...d,online:false});state.mode=data.mode||state.mode;
 if(!state.devices.some(d=>d.id===state.selected)){state.selected=state.devices[0]?.id||null;resetDraft();}
 if(!state.dirty)resetDraft();
 render();
}
function selectRoom(id){if(state.busy)return;state.selected=id;try{localStorage.setItem('daikin-selected-room',id);}catch{}resetDraft();state.lastStatus='';render();}
function markChanged(){const d=selectedDevice();state.dirty=!!d&&Object.keys(state.draft).some(key=>state.draft[key]!==d[key]);state.lastStatus='';state.statusType='';renderControls();}
function renderRooms(){
 const grid=$('room-grid');grid.replaceChildren();
 for(const d of state.devices){
  const button=document.createElement('button');button.className=`room-card${d.id===state.selected?' selected':''}${!d.online?' offline':''}`;button.disabled=state.busy;button.setAttribute('aria-pressed',String(d.id===state.selected));
  const roomIcon=document.createElement('span');roomIcon.className='room-icon';roomIcon.innerHTML=icon('room');button.append(roomIcon);
  const details=document.createElement('span');details.className='room-details';const name=document.createElement('strong');name.textContent=d.name||'Climatiseur';details.append(name);
  const subtitle=document.createElement('small');const dot=document.createElement('span');dot.className='status-dot';subtitle.append(dot,document.createTextNode(d.online?(d.power?modeLabel(d.mode):'Arrêté'):'Hors ligne'));details.append(subtitle);button.append(details);
  const temp=document.createElement('span');temp.className='room-temp';temp.append(document.createTextNode(temperature(d.roomTemperature)));const unit=document.createElement('small');unit.textContent='°';temp.append(unit);button.append(temp);
  button.addEventListener('click',()=>selectRoom(d.id));grid.append(button);
 }
 const online=state.devices.filter(d=>d.online).length;
 $('device-summary').textContent=state.devices.length?`${online} ${online>1?'connectées':'connectée'} sur ${state.devices.length}`:'Aucun appareil connecté';
 $('empty-state').hidden=state.devices.length>0;$('climate-panel').hidden=!selectedDevice();
}
function renderControls(){
 const d=selectedDevice();if(!d||!state.draft)return;const draft=state.draft;const canWrite=writable();const tempEnabled=canWrite&&temperatureAvailable();
 $('selected-room-name').textContent=d.name||'Climatiseur';$('power-label').textContent=state.busy?'Envoi en cours…':(d.power?'En marche':'Arrêté');
 $('power-button').disabled=!canWrite;$('power-button').setAttribute('aria-pressed',String(!!d.power));$('power-button').setAttribute('aria-label',d.power?'Éteindre le climatiseur':'Allumer le climatiseur');
 $('thermostat').classList.toggle('is-off',!d.power);$('target-caption').textContent=temperatureAvailable()?'Température souhaitée':'Température non réglable';
 $('target-value').textContent=temperatureAvailable()?temperature(draft.target):'—';$('dial-mode').innerHTML=icon(draft.mode);$('dial-mode').append(document.createTextNode(modeLabel(draft.mode)));
 const limits=limitsForDraft();const number=Number(draft.target);const fraction=Number.isFinite(number)&&draft.target!==null?Math.max(0,Math.min(1,(number-limits.min)/(limits.max-limits.min))):0;
 $('dial-progress').style.strokeDasharray=`${temperatureAvailable()?Math.max(12,fraction*622):0} 830`;
 $('temperature-minus').disabled=!tempEnabled||draft.target===null||number<=limits.min;$('temperature-plus').disabled=!tempEnabled||draft.target===null||number>=limits.max;
 $('target-hint').textContent=temperatureAvailable()?(draft.target===null?'Appliquez le mode d’abord':`Par pas de ${temperature(limits.step||.5)} °C`):'Selon le mode choisi';
 $('room-temperature').textContent=`${temperature(d.roomTemperature)} °C`;$('outdoor-temperature').textContent=`${temperature(d.outdoorTemperature)} °C`;
 document.querySelectorAll('.mode-button').forEach(button=>{button.disabled=!canWrite;button.classList.toggle('active',button.dataset.mode===draft.mode);button.setAttribute('aria-pressed',String(button.dataset.mode===draft.mode));});
 $('fan-select').value=draft.fan||'auto';$('fan-select').disabled=!canWrite||!d.capabilities?.fan;
 $('swing-select').value=draft.swing||'off';$('swing-select').disabled=!canWrite||!d.capabilities?.swing;
 $('apply-button').disabled=!canWrite||!state.dirty;$('apply-button').firstChild.textContent=state.busy?'Application en cours…':'Appliquer les réglages';
 $('draft-status').textContent=!d.online?'Appareil hors ligne. Actualisez pour rétablir la connexion.':!state.session?.writesEnabled?'Le pilotage est désactivé sur ce serveur.':state.dirty?(temperatureAvailable()&&draft.target===null?'Appliquez ce mode pour lire sa température mémorisée.':'Réglages modifiés. Appliquez pour les envoyer.'):'Les réglages actuels de votre clim.';
 $('control-status').textContent=state.lastStatus;$('control-status').className=`control-status ${state.statusType}`;
 $('device-status').textContent=d.online?'Connecté au réseau local':'Données précédentes · appareil hors ligne';$('device-status-dot').classList.toggle('stale',!d.online);
 const date=d.observedAt?new Date(d.observedAt):null;$('observed-time').textContent=date&&!Number.isNaN(date.getTime())?`Relevé à ${date.toLocaleTimeString('fr-FR',{hour:'2-digit',minute:'2-digit'})}`:'';
}
function renderConnection(){
 const list=$('connection-device-list');list.replaceChildren();
 for(const d of state.devices){const row=document.createElement('div');row.className='connection-device';const identity=document.createElement('div');const name=document.createElement('strong');name.textContent=d.name||'Climatiseur';const address=document.createElement('small');address.textContent=d.id;identity.append(name,address);const status=document.createElement('span');status.className=`status-pill${d.online?'':' offline'}`;status.textContent=d.online?'Connecté':'Hors ligne';row.append(identity,status);list.append(row);}
 const disabled=state.busy||state.refreshing||!state.session?.csrfToken;$('discover-button').disabled=disabled;$('connect-button').disabled=disabled;$('host-input').disabled=state.busy;
}
function render(){renderRooms();renderControls();renderConnection();$('refresh-button').disabled=state.refreshing||state.busy;const notice=state.notice||(state.mode==='test'?'Mode de démonstration : aucun climatiseur réel n’est commandé.':!state.session?.writesEnabled?'Le pilotage est désactivé. Les températures restent consultables.':'');$('global-notice').textContent=notice;$('global-notice').hidden=!notice;$('global-notice').classList.toggle('test-mode',state.mode==='test'&&!state.notice);}
async function refresh({initial=false}={}){
 if(state.refreshing||state.busy)return;state.refreshing=true;$('refresh-button').disabled=true;renderControls();renderConnection();
 try{if(initial||!state.session){state.session=await request('/api/session');$('about-model').textContent=state.session.model||'FTXA20A2V1BW';}const result=await request('/api/devices');state.notice='';ingest(result);}
 catch(error){state.notice=error.message;state.devices=state.devices.map(d=>({...d,online:false}));render();}
 finally{state.refreshing=false;render();}
}
// This function is called only by the explicit power or Apply button handlers.
// The interface reports success only after the backend verifies the new state.
async function control(changes){
 if(!writable())return;const id=state.selected;state.busy=true;state.lastStatus='Envoi au climatiseur…';state.statusType='';render();
 try{
  const result=await request(`/api/devices/${encodeURIComponent(id)}/control`,{method:'POST',body:{changes}});
  if(result.device){state.devices=state.devices.map(d=>d.id===id?result.device:d);}
  if(result.verified){resetDraft();state.lastStatus='Réglages confirmés par le climatiseur.';state.statusType='success';}
  else{state.lastStatus=result.message||'La commande a été envoyée, mais sa confirmation n’est pas disponible. Actualisez avant de réessayer.';state.statusType='error';const d=state.devices.find(d=>d.id===id);if(d)d.online=false;}
 }catch(error){state.lastStatus=error.message;state.statusType='error';const d=state.devices.find(d=>d.id===id);if(d)d.online=false;}
 finally{state.busy=false;render();}
}
function page(name){const connection=name==='connexion';$('page-maison').hidden=connection;$('page-connexion').hidden=!connection;document.querySelectorAll('[data-page]').forEach(button=>{const active=button.dataset.page===name;button.classList.toggle('active',active);if(active)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');});}
for(const mode of modes){const button=document.createElement('button');button.className='mode-button';button.dataset.mode=mode.id;button.innerHTML=icon(mode.id);const label=document.createElement('span');label.textContent=mode.label;button.append(label);button.setAttribute('aria-label',mode.id==='dry'?'Déshumidification':mode.label);button.addEventListener('click',()=>{if(!writable())return;state.draft.mode=mode.id;if(temperatureAvailable()&&typeof state.draft.target==='number'){const limits=limitsForDraft();state.draft.target=Math.max(limits.min,Math.min(limits.max,state.draft.target));}markChanged();});$('mode-options').append(button);}
document.querySelectorAll('[data-page]').forEach(button=>button.addEventListener('click',()=>page(button.dataset.page)));
document.querySelector('.brand').addEventListener('click',event=>{event.preventDefault();page('maison');});
document.querySelectorAll('[data-go-connection]').forEach(button=>button.addEventListener('click',()=>page('connexion')));
$('refresh-button').addEventListener('click',()=>refresh());
for(const [id,direction] of [['temperature-minus',-1],['temperature-plus',1]]){$(id).addEventListener('click',()=>{if(!writable()||!temperatureAvailable())return;const limits=limitsForDraft();state.draft.target=Math.max(limits.min,Math.min(limits.max,Math.round((state.draft.target+direction*(limits.step||.5))*10)/10));markChanged();});}
$('fan-select').addEventListener('change',event=>{if(!writable())return;state.draft.fan=event.target.value;markChanged();});
$('swing-select').addEventListener('change',event=>{if(!writable())return;state.draft.swing=event.target.value;markChanged();});
$('power-button').addEventListener('click',()=>{const d=selectedDevice();if(d)control({power:!d.power});});
$('apply-button').addEventListener('click',()=>{
 const d=selectedDevice();if(!d||!state.dirty)return;const changes={};
 for(const key of ['mode','target','fan','swing']){if(key==='target'&&!temperatureAvailable())continue;if(key==='fan'&&!d.capabilities?.fan)continue;if(key==='swing'&&!d.capabilities?.swing)continue;if(state.draft[key]!==d[key])changes[key]=state.draft[key];}
 if(Object.keys(changes).length)control(changes);else{resetDraft();renderControls();}
});
$('discover-button').addEventListener('click',async()=>{
 if(state.busy)return;state.busy=true;$('discover-status').textContent='Recherche sur le réseau local…';render();
 try{const data=await request('/api/discover',{method:'POST',body:{}});ingest(data);$('discover-status').textContent=data.devices?.length?`${data.devices.length} climatiseur${data.devices.length>1?'s':''} trouvé${data.devices.length>1?'s':''}.`:'Aucun climatiseur trouvé. Vérifiez la connexion Wi-Fi ou ajoutez son adresse IP.';}
 catch(error){$('discover-status').textContent=error.message;}
 finally{state.busy=false;render();}
});
$('connect-form').addEventListener('submit',async event=>{
 event.preventDefault();if(state.busy)return;const host=$('host-input').value.trim();if(!host)return;state.busy=true;$('connect-status').textContent='Vérification de la connexion…';render();
 try{const data=await request('/api/connect',{method:'POST',body:{host}});ingest(data);$('connect-status').textContent='Climatiseur ajouté à votre maison.';$('host-input').value='';}
 catch(error){$('connect-status').textContent=error.message;}
 finally{state.busy=false;render();}
});
$('about-button').addEventListener('click',()=>$('about-dialog').showModal());$('close-dialog').addEventListener('click',()=>$('about-dialog').close());$('about-dialog').addEventListener('click',event=>{if(event.target===$('about-dialog')){const bounds=event.target.getBoundingClientRect();if(event.clientX<bounds.left||event.clientX>bounds.right||event.clientY<bounds.top||event.clientY>bounds.bottom)event.target.close();}});
// Background polling only reads. It pauses while a command is in flight and
// while this browser tab is hidden. Switching modes alone never sends a command.
await refresh({initial:true});
setInterval(()=>{if(!document.hidden)refresh();},30000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh();});
