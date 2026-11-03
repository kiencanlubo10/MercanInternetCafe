/* Mock of the Supabase client for UI tests. It mimics the payroll SQL rules
   (it proves the screens work, NOT that the SQL is right: the SQL has its own test). */
(function(){
  const params=new URLSearchParams(location.search);
  const ROLE=params.get('role')||'admin';
  const FAIL_LIST=params.get('missing')==='1';
  const money2=n=>Math.round(n*100)/100;
  const db={
    revision:41,
    state:{version:1,settings:{shopName:'Mercan Internet Cafe'},categories:['Electricity'],
      sales:[{id:'s1',date:'2026-10-05',morning:1000,night:500},{id:'s2',date:'2026-10-15',morning:500,night:0},
             {id:'s3',date:'2026-10-16',morning:3000,night:0},{id:'s4',date:'2026-10-31',morning:0,night:1000}],
      expenses:[{id:'e1',date:'2026-10-10',category:'Electricity',description:'bill',amount:400},{id:'e2',date:'2026-10-20',category:'Electricity',description:'rent',amount:5000}],
      employees:[{id:'emp-a',name:'Alpha Cruz',rate:10,salary:20000},{id:'emp-b',name:'Bravo Reyes',rate:0,salary:10000}],payments:[]},
    registry:[],deductions:[
      {id:'d1',employee_ref:'emp-a',salary_month:'2026-10',payout_period:'15th',kind:'deduction',amount:1000,reference:'DED-1',note:'advance',run:null},
      {id:'d2',employee_ref:'emp-b',salary_month:'2026-10',payout_period:'30th',kind:'deduction',amount:6000,reference:'DED-2',note:'big',run:null}],
    runs:[],adjustments:[],seq:0,calls:[]
  };
  window.__db=db;
  const err=m=>({data:null,error:{message:'ERROR:  '+m}});
  function windowFor(month,period){const [y,m]=month.split('-').map(Number);
    const last=new Date(Date.UTC(y,m,0)).getUTCDate();const p=n=>String(n).padStart(2,'0');
    return period==='15th'?[`${month}-01`,`${month}-15`]:[`${month}-16`,`${month}-${p(last)}`]}
  function calc(ref,month,period,from,to){
    const reg=db.registry.find(r=>r.employee_ref===ref);if(!reg)throw new Error('Employee not found in the payroll registry. Open the Employees page once so the roster syncs.');
    if(!/^\d{4}-(0[1-9]|1[0-2])$/.test(month||''))throw new Error('Salary month must look like 2026-11');
    let [f,t]=windowFor(month,period);f=from||f;t=to||t;
    const gross=db.state.sales.filter(s=>s.date>=f&&s.date<=t).reduce((a,s)=>a+Number(s.morning||0)+Number(s.night||0),0);
    const bills=db.state.expenses.filter(s=>s.date>=f&&s.date<=t).reduce((a,s)=>a+Number(s.amount||0),0);
    const net=gross-bills,comm=money2(Math.max(0,net)*reg.commission_rate/100),basic=money2(reg.monthly_salary/2);
    const lines=[{line_type:'basic',description:'Basic pay (half of monthly salary)',amount:basic},{line_type:'commission',description:`Commission ${reg.commission_rate}% of net sales ${f} to ${t}`,amount:comm}];
    let ded=0;db.deductions.filter(d=>d.employee_ref===ref&&d.salary_month===month&&d.payout_period===period&&!d.run).forEach(d=>{
      if(d.kind==='deduction'){ded+=d.amount;lines.push({line_type:'deduction',deduction_id:d.id,description:d.reference+' - '+d.note,amount:-d.amount})}});
    const netPay=basic+comm-ded;
    const existing=db.runs.find(r=>r.employee_ref===ref&&r.salary_month===month&&r.payout_period===period&&r.status==='processed');
    const warnings=[];if(t>new Date().toISOString().slice(0,10))warnings.push('The commission period has not ended yet; sales recorded after payroll is processed will not be paid.');
    return {employee_ref:ref,employee_name:reg.name,active:reg.active,salary_month:month,payout_period:period,monthly_salary:reg.monthly_salary,basic_pay:basic,
      commission_rate:reg.commission_rate,commission_from:f,commission_to:t,period_gross:gross,period_bills:bills,period_net:net,commission_amount:comm,
      deductions_total:ded,net_pay:netPay,lines,warnings,already_processed:!!existing,existing_reference:existing?existing.reference:null,
      blocked_reason:existing?`Payroll ${existing.reference} already exists for this employee, month and payout`:
        netPay<0?`Deductions (${ded}) exceed basic pay plus commission (${basic+comm}). Reverse or reduce deductions first.`:null};
  }
  function withAdj(r){const a=db.adjustments.filter(x=>x.payroll_run_id===r.id);const tot=a.reduce((s,x)=>s+x.amount,0);
    return {...r,adjustments_total:tot,final_net_pay:r.net_pay+tot,adjustments:a,lines:r.lines_saved}}
  const rpcs={
    bootstrap_mercanshop:()=>({shop_id:'shop-1',role:ROLE}),
    save_shop_state:a=>{db.revision++;db.state=a.p_state;return db.revision},
    save_shop_state_p4:a=>{db.revision++;db.state=a.p_state;return db.revision},
    my_permissions:()=>({role:ROLE,sales:ROLE!=='staff',expenses:ROLE!=='staff',employees:ROLE!=='staff',settings:ROLE!=='staff'}),
    start_session:()=>'sess-1',touch_session:()=>null,end_session:()=>null,
    list_team:()=>[{user_id:'u-admin',email:'owner@example.com',role:'admin',active:true,last_seen_at:new Date().toISOString(),online:true,permissions:{sales:true,expenses:true,employees:true,settings:true}},{user_id:'u-staff',email:'cashier01@accounts.mercan.invalid',role:'staff',active:true,last_seen_at:null,online:false,permissions:{sales:false,expenses:false,employees:false,settings:false}}],
    list_login_history:()=>[{id:1,user_id:'u-staff',email:'cashier01@accounts.mercan.invalid',event:'login',device:'Test browser',created_at:new Date().toISOString()}],
    set_member_permission:()=>null,revoke_member_sessions:()=>({sessions_ended:1,tokens_removed:true}),set_member_active:()=>null,
    sync_employee_registry:a=>{db.registry=a.p_employees.map(e=>({employee_ref:e.id,name:e.name,monthly_salary:e.salary,commission_rate:e.rate,active:true}));return db.registry.length},
    preview_payroll:a=>{need();return calc(a.p_employee_ref,a.p_salary_month,a.p_payout_period,a.p_commission_from,a.p_commission_to)},
    process_payroll_run:a=>{need();const c=calc(a.p_employee_ref,a.p_salary_month,a.p_payout_period,a.p_commission_from,a.p_commission_to);
      if(c.blocked_reason)throw new Error(c.blocked_reason);
      if(a.p_expected_net!=null&&money2(a.p_expected_net)!==c.net_pay)throw new Error(`The figures changed since the preview (now ${c.net_pay}, was ${a.p_expected_net}). Preview again before processing.`);
      db.seq++;const run={id:'run-'+db.seq,reference:'PAY-20261103-'+String(db.seq).padStart(5,'0'),employee_ref:c.employee_ref,employee_name:c.employee_name,salary_month:c.salary_month,
        payout_period:c.payout_period,status:'processed',paid_on:a.p_paid_on,monthly_salary:c.monthly_salary,basic_pay:c.basic_pay,commission_rate:c.commission_rate,
        commission_from:c.commission_from,commission_to:c.commission_to,period_gross:c.period_gross,period_bills:c.period_bills,period_net:c.period_net,
        commission_amount:c.commission_amount,deductions_total:c.deductions_total,net_pay:c.net_pay,notes:a.p_notes,processed_by_name:'admin',processed_at:new Date().toISOString(),lines_saved:c.lines};
      db.runs.push(run);c.lines.forEach(l=>{if(l.deduction_id)db.deductions.find(d=>d.id===l.deduction_id).run=run.id});return run},
    add_payroll_adjustment:a=>{need();const r=db.runs.find(x=>x.id===a.p_run_id);if(!r)throw new Error('Payroll run not found');
      if(!a.p_amount)throw new Error('Adjustment amount cannot be zero');if((a.p_reason||'').trim().length<3)throw new Error('A reason is required for a payroll adjustment');
      const cur=withAdj(r).final_net_pay;if(cur+a.p_amount<0)throw new Error(`This adjustment would make the final net pay negative (currently ${cur})`);
      const adj={id:'adj-'+(db.adjustments.length+1),reference:'ADJ-20261103-'+String(db.adjustments.length+1).padStart(5,'0'),payroll_run_id:r.id,amount:a.p_amount,reason:a.p_reason,created_by_name:'admin',created_at:new Date().toISOString()};
      db.adjustments.push(adj);return adj},
    list_payroll_runs:a=>{need();if(FAIL_LIST)throw new Error('Could not find the function public.list_payroll_runs(p_employee_ref, p_limit, p_month, p_offset) in the schema cache');
      return db.runs.filter(r=>(!a.p_month||r.salary_month===a.p_month)&&(!a.p_employee_ref||r.employee_ref===a.p_employee_ref)).map(withAdj).reverse()}
  };
  function need(){if(ROLE!=='admin')throw new Error('Only a shop administrator can do this')}
  const rpc=(name,args)=>{db.calls.push({name,args});return new Promise(res=>setTimeout(()=>{try{const f=rpcs[name];if(!f)return res(err('Could not find the function public.'+name+' in the schema cache'));res({data:JSON.parse(JSON.stringify(f(args||{}))),error:null})}catch(e){res(err(e.message))}},5))};
  function builder(table){let rows=[];
    if(table==='shop_state')rows=[{state:db.state,revision:db.revision}];
    else if(table==='employee_registry')rows=db.registry;
    const b={select:()=>b,eq:()=>b,order:()=>b,range:()=>b,or:()=>b,gte:()=>b,lte:()=>b,not:()=>b,
      maybeSingle:()=>Promise.resolve({data:rows[0]||null,error:null}),single:()=>Promise.resolve({data:rows[0]||null,error:null}),
      then:(ok,bad)=>Promise.resolve({data:rows,error:null,count:rows.length}).then(ok,bad)};return b}
  window.supabase={createClient:()=>({
    auth:{getSession:async()=>({data:{session:{user:{id:'u1'}}},error:null}),onAuthStateChange:()=>({data:{subscription:{}}}),signOut:async()=>{},signInWithPassword:async()=>({}),signUp:async()=>({})},
    rpc,from:builder,channel:()=>({on(){return this},subscribe(){return this}}),removeChannel:async()=>{},functions:{invoke:async()=>({data:{}})}})};
})();
