(function(){
  "use strict";

  /* ---------- theme ---------- */
  var root=document.documentElement, tBtn=document.getElementById('themeBtn');
  var saved=null; try{saved=localStorage.getItem('ps5img-theme');}catch(e){}
  function setTheme(t){
    if(t==='light'){root.setAttribute('data-theme','light');if(tBtn)tBtn.textContent='深色';}
    else{root.removeAttribute('data-theme');if(tBtn)tBtn.textContent='浅色';}
    try{localStorage.setItem('ps5img-theme',t);}catch(e){}
  }
  setTheme(saved==='light'?'light':'dark');
  if(tBtn)tBtn.addEventListener('click',function(){setTheme(root.getAttribute('data-theme')==='light'?'dark':'light');});

  /* ---------- EN toggle ---------- */
  var eBtn=document.getElementById('enBtn');
  var enOn=true; try{enOn=localStorage.getItem('ps5img-en')!=='off';}catch(e){}
  function setEn(on){
    enOn=on; document.body.classList.toggle('show-en',on);
    if(eBtn)eBtn.classList.toggle('on',on);
    try{localStorage.setItem('ps5img-en',on?'on':'off');}catch(e){}
  }
  setEn(enOn);
  if(eBtn)eBtn.addEventListener('click',function(){setEn(!enOn);});

  /* ---------- mobile TOC ---------- */
  var toc=document.getElementById('toc'), mBtn=document.getElementById('menuBtn');
  if(mBtn&&toc){
    mBtn.addEventListener('click',function(){toc.classList.toggle('open');});
    toc.addEventListener('click',function(e){if(e.target.tagName==='A')toc.classList.remove('open');});
  }

  /* ---------- mark current page in the top nav ---------- */
  var here=(location.pathname.split('/').pop()||'index.html').toLowerCase();
  Array.prototype.forEach.call(document.querySelectorAll('.pnav a'),function(a){
    var h=(a.getAttribute('href')||'').toLowerCase();
    if(h===here||(here===''&&h==='index.html'))a.classList.add('active');
  });

  /* ---------- copy buttons: command blocks only ---------- */
  Array.prototype.forEach.call(document.querySelectorAll('.code'),function(box){
    var btn=box.querySelector('.copy');
    if(!btn)return;
    var cmds=Array.prototype.slice.call(box.querySelectorAll('pre.cmd'));
    if(!cmds.length){btn.parentNode.removeChild(btn);return;}
    btn.title='只复制命令区，不含输出 / copy the command blocks only';
    btn.addEventListener('click',function(){
      // Only pre.cmd is copied; pre.outp (command output) is never included.
      // 只复制 pre.cmd 命令区，pre.outp 输出区永不包含；行首 $ 与 > 提示符会被去掉。
      var txt=cmds.map(function(p){
        return p.textContent.replace(/^\$ /gm,'').replace(/^> /gm,'').replace(/^\n+/,'').replace(/\s+$/,'');
      }).join('\n');
      function done(){btn.textContent='copied';btn.classList.add('done');
        setTimeout(function(){btn.textContent='copy';btn.classList.remove('done');},1400);}
      if(navigator.clipboard&&navigator.clipboard.writeText){
        navigator.clipboard.writeText(txt).then(done,function(){fallback(txt,done);});
      }else{fallback(txt,done);}
    });
  });
  function fallback(txt,cb){
    var ta=document.createElement('textarea');ta.value=txt;
    ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);
    ta.select();try{document.execCommand('copy');}catch(e){}document.body.removeChild(ta);cb();
  }

  /* ---------- scroll spy ---------- */
  var links=Array.prototype.slice.call(document.querySelectorAll('nav.toc a[href^="#"]'));
  if(links.length){
    var secs=links.map(function(a){return document.querySelector(a.getAttribute('href'));}).filter(Boolean);
    var spy=function(){
      if(!secs.length)return;
      var y=window.scrollY+120,cur=secs[0];
      secs.forEach(function(s){if(s.offsetTop<=y)cur=s;});
      links.forEach(function(a){a.classList.toggle('active',a.getAttribute('href')==='#'+cur.id);});
    };
    var ticking=false;
    window.addEventListener('scroll',function(){
      if(ticking)return;ticking=true;requestAnimationFrame(function(){spy();ticking=false;});
    },{passive:true});
    spy();
  }

  /* ---------- image size calculator (exFAT page only) ---------- */
  var iSize=document.getElementById('cSize'), iFiles=document.getElementById('cFiles'),
      cOut=document.getElementById('calcOut');
  if(iSize&&iFiles&&cOut){
    var CLS=65536, META=32*1024*1024, SLACK=64*1024*1024,
        SPARE_MIN=64*1024*1024, SPARE_MAX=512*1024*1024, ENTRY=256;
    var calc=function(){
      var gib=parseFloat(iSize.value), files=parseInt(iFiles.value,10);
      if(!isFinite(gib)||gib<=0){cOut.innerHTML='<div>请输入一个大于 0 的体积。</div>';return;}
      if(!isFinite(files)||files<1)files=1;
      var raw=Math.round(gib*1024*1024*1024);
      var dirs=Math.max(1,Math.round(files/5));
      var avg=raw/files;
      var data=Math.ceil(avg/CLS)*CLS*files;            // per-file cluster rounding
      var clusters=Math.ceil(data/CLS);
      var fat=clusters*4, bmp=Math.ceil(clusters/8), ent=(files+dirs)*ENTRY;
      var base=data+fat+bmp+ent+META;
      var spare=Math.min(SPARE_MAX,Math.max(SPARE_MIN,Math.round(base/200)));
      var total=Math.max(base+spare,raw+SLACK);
      var mib=Math.ceil(total/1048576);
      var needGib=(mib/1024*2);
      var profile = avg>=1048576 ? '64 KiB 簇（本教程固定使用）' : '平均文件偏小，官方脚本会自动降到 32 KiB 簇';
      cOut.innerHTML=
        '<div>数据区含簇末填充：<b>'+(data/1024/1024/1024).toFixed(2)+' GiB</b></div>'+
        '<div>建议镜像大小：<b>'+mib.toLocaleString()+' MiB</b>（约 '+(mib/1024).toFixed(1)+' GiB）</div>'+
        '<div>换算成 <code class="inl">mkfile -n</code> 参数：<b>'+(mib+1024)+'g</b>（留 1 GiB 余量更稳妥）</div>'+
        '<div>源与镜像同盘时需空闲：<span class="em">约 '+needGib.toFixed(0)+' GiB</span></div>'+
        '<div style="color:var(--text-faint);font-size:12.5px;margin-top:8px">簇大小判断：'+profile+'</div>';
    };
    iSize.addEventListener('input',calc); iFiles.addEventListener('input',calc); calc();
  }

  /* ---------- format decider (home page only) ---------- */
  var dec=document.getElementById('decider');
  if(dec){
    var dOut=document.getElementById('decideOut');
    var mark=function(){
      Array.prototype.forEach.call(dec.querySelectorAll('.opt'),function(o){
        var i=o.querySelector('input');
        o.classList.toggle('sel',!!(i&&i.checked));
      });
    };
    var val=function(n){
      var e=dec.querySelector('input[name="'+n+'"]:checked');return e?e.value:null;
    };
    var evaluate=function(){
      var w=val('dWhere'), c=val('dCompat'), k=val('dCare');
      mark();
      if(!w||!c||!k){
        dOut.innerHTML='<div style="color:var(--text-faint);font-size:13px">把上面三题都选一下，这里会给出推荐与理由。</div>';
        return;
      }
      var rec, why=[], note='';
      if(c==='yes'){
        rec='exfat';
        why.push('你确认这个游戏<strong>只有在按「外置盘内容」处理时才正常</strong>——这正是 <code class="inl">exFAT</code> 存在的唯一理由，官方也只在这种情况推荐它。');
      }else{
        rec='ffpkg';
        if(k==='official')why.push('你选择跟随官方推荐：ShadowMountPlus 把 UFS（<code class="inl">.ffpkg</code>）列为推荐格式。');
        if(w==='internal')why.push('镜像要放进 PS5 内置存储：内置场景官方推荐 UFS，exFAT 在内置上还需要额外的只读/扇区设置。');
        if(k==='space')why.push('你在意空间占用：UFS2 的元数据开销比 exFAT 小，大文件游戏的浪费更少。');
        if(k==='steps')why.push('你想步骤最少：<code class="inl">newfs -D</code> 就一条命令，<strong>不挂载、不需要清理 macOS 残留文件</strong>。');
        if(w==='external'&&c==='unsure')why.push('外置盘 + 还没试过：两条路都能用。建议先做 <code class="inl">.ffpkg</code>，成本最低；万一这个游戏异常，再改做 <code class="inl">.exfat</code> 也不迟。');
        note='如果你已经有做好的 <code>.exfat</code>，<strong>不必重做</strong>——只有游戏真的异常时才需要换格式。';
      }
      var label=rec==='ffpkg'?'UFS2 镜像 · .ffpkg':'exFAT 镜像 · .exfat';
      dOut.innerHTML='<div class="dresult">'+
        '<div class="dr-h win-'+rec+'">推荐：'+label+'</div>'+
        '<ul>'+why.map(function(x){return '<li>'+x+'</li>';}).join('')+'</ul>'+
        (note?'<div style="font-size:12.5px;color:var(--text-faint);margin-top:9px">'+note+'</div>':'')+
        '<a class="dr-go" href="'+rec+'.html">→ 打开 '+(rec==='ffpkg'?'ffpkg (UFS2)':'exFAT')+' 完整教程</a>'+
        '</div>';
    };
    Array.prototype.forEach.call(dec.querySelectorAll('input'),function(i){
      i.addEventListener('change',evaluate);
    });
    evaluate();
  }

  /* ---------- pre-flight checklist ---------- */
  var boxes=Array.prototype.slice.call(document.querySelectorAll('#checkList input[type=checkbox]'));
  if(boxes.length){
    var KEY='ps5img-checks';
    var state=[]; try{state=JSON.parse(localStorage.getItem(KEY)||'[]');}catch(e){}
    boxes.forEach(function(b,i){
      b.checked=!!state[i];
      b.addEventListener('change',function(){
        try{localStorage.setItem(KEY,JSON.stringify(boxes.map(function(x){return x.checked;})));}catch(e){}
      });
    });
  }
})();
