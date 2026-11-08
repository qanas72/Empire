(function(){
  const path=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  if(path==='login.html') return;
  const adminPage=/^(admin|admin-|assets-admin|emperor-users|publishing-admin|vip-admin)/.test(path);
  const userLinks=[['🏠 Home','index.html'],['👤 Profile','profile.html'],['💬 Messages','messages.html'],['🔔 Notifications','notifications.html'],['👥 Members','members.html'],['📰 All Publications','all-publications.html'],['📝 Publishing','publishing.html'],['📚 My Publications','my-publications.html'],['🤝 My Team','my-team.html'],['👑 Premium / VIP','premium.html'],['🪙 EmpireCoin Wallet','wallet.html'],['🎟️ Raffles','raffle.html'],['ℹ️ About EMPIRE','about.html'],['🆘 Support','support.html']];
  const adminLinks=[['⚙️ Admin Dashboard','admin.html'],['👥 User Management','emperor-users.html'],['🪙 Assets Administration','assets-admin.html'],['👑 VIP Administration','vip-admin.html'],['📝 Publication Reports','publishing-admin.html'],['🔔 Admin Notifications','admin-notifications.html'],['🆘 Admin Support','admin-support.html'],['🏠 Public Website','index.html']];
  const host=document.querySelector('header')||document.querySelector('.messages-topbar')||document.querySelector('.top');
  if(!host)return;
  let nav=host.querySelector('nav');
  let back=host.querySelector('.page-back,.back-nav,.nav-back,.back-btn');
  if(back){
    back.remove();
    back.classList.add('empire-page-back');
    if(!back.textContent.trim()||back.textContent.trim()==='←')back.textContent='← Back';
    host.insertBefore(back,nav||host.firstChild);
  }else if(path!=='index.html'){
    back=document.createElement('button');
    back.type='button';back.className='empire-page-back';back.textContent='← Back';
    back.setAttribute('aria-label','Go back');
    back.addEventListener('click',()=>{if(history.length>1)history.back();else location.href='index.html';});
    host.insertBefore(back,nav||host.firstChild);
  }
  if(!nav){
    nav=document.createElement('nav');
    (adminPage?adminLinks:userLinks).forEach(([label,href])=>{const a=document.createElement('a');a.href=href;a.textContent=label;nav.appendChild(a);});
  }else if(nav.querySelectorAll('a').length<=1){
    (adminPage?adminLinks:userLinks).forEach(([label,href])=>{if(!Array.from(nav.querySelectorAll('a')).some(a=>a.getAttribute('href')===href)){const a=document.createElement('a');a.href=href;a.textContent=label;nav.appendChild(a);}});
  }
  const existing=host.querySelector('.menu,.menu-btn,.profile-menu-toggle,.empire-global-toggle');
  const toggle=existing||document.createElement('button');
  toggle.type='button';toggle.classList.add('empire-global-toggle');toggle.setAttribute('aria-label','Open navigation menu');toggle.setAttribute('aria-expanded','false');toggle.innerHTML='<span class="empire-toggle-icon">☷</span><span>MENU</span>';
  if(!existing)host.appendChild(toggle);
  if(existing){existing.removeAttribute('onclick');existing.classList.add('empire-global-toggle');existing.innerHTML='<span class="empire-toggle-icon">☷</span><span>MENU</span>';}
  const backdrop=document.createElement('div');backdrop.className='empire-drawer-backdrop';backdrop.setAttribute('aria-hidden','true');
  const drawer=document.createElement('aside');drawer.className='empire-global-drawer';drawer.setAttribute('aria-label','EMPIRE navigation');drawer.setAttribute('aria-hidden','true');
  const head=document.createElement('div');head.className='empire-global-drawer-head';head.innerHTML='<span>👑 EMPIRE MENU</span><button type="button" aria-label="Close menu">×</button>';
  drawer.appendChild(head);drawer.appendChild(nav);document.body.appendChild(backdrop);document.body.appendChild(drawer);
  function close(){drawer.classList.remove('is-open');backdrop.classList.remove('is-open');drawer.setAttribute('aria-hidden','true');backdrop.setAttribute('aria-hidden','true');toggle.setAttribute('aria-expanded','false');}
  function open(){drawer.classList.add('is-open');backdrop.classList.add('is-open');drawer.setAttribute('aria-hidden','false');backdrop.setAttribute('aria-hidden','false');toggle.setAttribute('aria-expanded','true');}
  toggle.addEventListener('click',()=>drawer.classList.contains('is-open')?close():open());backdrop.addEventListener('click',close);head.querySelector('button').addEventListener('click',close);drawer.querySelectorAll('a').forEach(a=>a.addEventListener('click',close));document.addEventListener('keydown',e=>{if(e.key==='Escape')close();});
})();