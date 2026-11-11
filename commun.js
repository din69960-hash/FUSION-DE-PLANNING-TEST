// =====================================================================
// FUSION DE PLANNING — code commun aux trois pages
// (connexion Supabase, session, saisons)
// =====================================================================
const FU_URL = 'https://nvufzwdwhearlwdcezsn.supabase.co';
const FU_KEY = 'sb_publishable_Ts29xuGykGP-xQ7R5ldKYg_J8Ywxnwl';
const FU_MOIS = ['Septembre','Octobre','Novembre','Décembre','Janvier','Février','Mars','Avril','Mai','Juin','Juillet','Aout'];

const FU = {
  sb: null,
  session: null,      // { token, role: 'asso'|'admin', nom }
  saisons: [],        // [{annee, creneaux_ouvert, manif_ouvert}]
  saison: null,       // année de la saison choisie

  client(){
    if(!FU.sb && window.supabase && window.supabase.createClient) FU.sb = window.supabase.createClient(FU_URL, FU_KEY);
    return FU.sb;
  },

  // ---------- Session (gardée dans l'onglet uniquement, jamais le mot de passe) ----------
  lireSession(){
    try{ FU.session = JSON.parse(sessionStorage.getItem('ft_session')||'null'); }catch(e){ FU.session = null; }
    return FU.session;
  },
  ecrireSession(s){
    FU.session = s;
    if(s) sessionStorage.setItem('ft_session', JSON.stringify(s)); else sessionStorage.removeItem('ft_session');
  },
  async rpc(fn, args){
    const sb = FU.client();
    if(!sb) throw new Error('Base de données indisponible (connexion internet ?)');
    const {data, error} = await sb.rpc(fn, args||{});
    if(error){
      if(error.code === '28000'){ FU.sessionExpiree(); }
      throw new Error(error.message || 'Erreur serveur');
    }
    return data;
  },
  sessionExpiree(){
    FU.ecrireSession(null);
    if(document.body && document.body.dataset.page === 'portail'){
      if(window.portailSessionExpiree) window.portailSessionExpiree();
    } else {
      setTimeout(() => { location.href = 'index.html?expire=1'; }, 1200);
    }
  },
  // Vérifie le jeton auprès de la base ; renvoie la session ou redirige vers l'accueil
  async exigerSession(role){
    const s = FU.lireSession();
    if(!s || !s.token){ location.href = 'index.html'; return null; }
    let r = null;
    try{ r = await FU.rpc('ft_session_info', {p_token: s.token}); }catch(e){ r = null; }
    if(!r || !r.valide || (role && r.role !== role && !(Array.isArray(role) && role.includes(r.role)))){
      FU.ecrireSession(null); location.href = 'index.html?expire=1'; return null;
    }
    s.role = r.role; if(r.nom) s.nom = r.nom;
    FU.ecrireSession(s);
    return s;
  },
  async deconnexion(){
    const s = FU.lireSession();
    if(s && s.token){ try{ await FU.client().rpc('ft_deconnexion', {p_token: s.token}); }catch(e){} }
    FU.ecrireSession(null);
    sessionStorage.removeItem('ft_saison');
    location.href = 'index.html';
  },

  // ---------- Saisons ----------
  saisonParDefaut(){
    const d = new Date(), y = d.getMonth() >= 8 ? d.getFullYear() : d.getFullYear() - 1;   // septembre → août
    return y;
  },
  async chargerSaisons(){
    const sb = FU.client();
    const {data, error} = await sb.from('ft_saisons').select('annee,creneaux_ouvert,manif_ouvert').order('annee');
    if(error) throw error;
    FU.saisons = data || [];
    let an = parseInt(sessionStorage.getItem('ft_saison')||'', 10);
    if(!FU.saisons.some(x => x.annee === an)){
      const def = FU.saisonParDefaut();
      an = FU.saisons.some(x => x.annee === def) ? def : (FU.saisons.length ? FU.saisons[FU.saisons.length-1].annee : def);
    }
    FU.choisirSaison(an);
    return FU.saisons;
  },
  choisirSaison(an){
    FU.saison = Number(an);
    sessionStorage.setItem('ft_saison', String(FU.saison));
  },
  infoSaison(an){ return FU.saisons.find(x => x.annee === Number(an || FU.saison)) || null; },
  libelleSaison(an){ an = Number(an || FU.saison); return an + '–' + (an + 1); },

  // ---------- Réglages partagés ----------
  async reglages(){
    const {data, error} = await FU.client().from('ft_reglages').select('cle,valeur');
    if(error) throw error;
    const o = {}; (data||[]).forEach(r => { o[r.cle] = r.valeur; });
    return o;
  },
  json(v, def){ if(v == null) return def; if(typeof v === 'object') return v; try{ return JSON.parse(v); }catch(e){ return def; } },
  esc(s){ return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); },
  norm(s){ return String(s||'').trim().replace(/\s+/g,' ').toLowerCase(); }
};

// ---------- Application installable (service worker) ----------
if('serviceWorker' in navigator){
  window.addEventListener('load', () => { navigator.serviceWorker.register('sw.js').catch(()=>{}); });
}

// ---------- Bandeau « SITE TEST » (ce site ne touche pas aux données réelles) ----------
document.addEventListener('DOMContentLoaded', () => {
  const b = document.createElement('div');
  b.textContent = 'SITE TEST';
  b.setAttribute('style', 'position:fixed;top:10px;left:-34px;z-index:99999;transform:rotate(-45deg);background:#c0392b;color:#fff;'
    + 'font:700 11px/1 sans-serif;letter-spacing:2px;padding:6px 40px;box-shadow:0 2px 6px rgba(0,0,0,.3);pointer-events:none;');
  document.body.appendChild(b);
});
