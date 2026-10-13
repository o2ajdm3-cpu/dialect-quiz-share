-- 새 Supabase 프로젝트의 SQL Editor에서 한 번 실행하세요.
create extension if not exists pgcrypto;
create table public.quiz_classes(id uuid primary key default gen_random_uuid(),code text not null unique,name text not null,teacher_hash text not null,phase text not null default 'creating' check(phase in ('creating','review','playing','finished')),created_at timestamptz not null default now());
create table public.quiz_students(id uuid primary key default gen_random_uuid(),class_id uuid not null references public.quiz_classes on delete cascade,name text not null,team text not null,secret_hash text not null,created_at timestamptz not null default now(),unique(class_id,name));
create table public.quiz_questions(id uuid primary key default gen_random_uuid(),class_id uuid not null references public.quiz_classes on delete cascade,author_id uuid not null references public.quiz_students on delete cascade,team text not null,body text not null,options jsonb not null,correct int not null check(correct between 1 and 4),status text not null default 'available' check(status in ('available','claimed','answered')),claimed_by uuid,claimed_at timestamptz,answered_by uuid,created_at timestamptz not null default now());
create table public.quiz_attempts(id uuid primary key default gen_random_uuid(),class_id uuid not null references public.quiz_classes on delete cascade,question_id uuid not null references public.quiz_questions on delete cascade,student_id uuid not null references public.quiz_students on delete cascade,choice int not null,correct int not null,was_correct boolean not null,created_at timestamptz not null default now(),unique(question_id,student_id));
create index on public.quiz_questions(class_id,team,status);create index on public.quiz_attempts(class_id,created_at);
alter table public.quiz_classes enable row level security;alter table public.quiz_students enable row level security;alter table public.quiz_questions enable row level security;alter table public.quiz_attempts enable row level security;
revoke all on public.quiz_classes,public.quiz_students,public.quiz_questions,public.quiz_attempts from anon,authenticated;

create or replace function public.quiz_api(p jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a text:=p->>'action';c public.quiz_classes%rowtype;s public.quiz_students%rowtype;q public.quiz_questions%rowtype;v_code text:=upper(trim(coalesce(p->>'code','')));v_teacher boolean:=false;v_student boolean:=false;v_token text;v_choice int;v_id uuid;v_team text;v_name text;v_options jsonb;v_out jsonb;v_attempts jsonb;
begin
 if a='create' then
  v_name:=trim(coalesce(p->>'name',''));
  if length(v_name)<2 or length(v_name)>80 or length(coalesce(p->>'pin',''))<6 then raise exception '학급명(2자 이상)과 6자 이상 교사 비밀번호가 필요합니다.';end if;
  v_code:=upper(substr(encode(gen_random_bytes(6),'hex'),1,8));
  insert into public.quiz_classes(code,name,teacher_hash) values(v_code,v_name,crypt(p->>'pin',gen_salt('bf'))) returning * into c;
  return jsonb_build_object('code',c.code,'name',c.name);
 end if;
 select * into c from public.quiz_classes where code=v_code;
 if not found then raise exception '학급 코드를 확인하세요.';end if;
 v_teacher:=length(coalesce(p->>'pin',''))>0 and c.teacher_hash=crypt(p->>'pin',c.teacher_hash);
 if p ? 'studentId' and p ? 'token' then
  begin
   select * into s from public.quiz_students where id=(p->>'studentId')::uuid and class_id=c.id;
   v_student:=found and s.secret_hash=encode(digest(p->>'token','sha256'),'hex');
  exception when invalid_text_representation then v_student:=false;
  end;
 end if;
 if a='teacherLogin' then
  if not v_teacher then raise exception '교사 비밀번호가 틀렸습니다.';end if;
  return jsonb_build_object('ok',true);
 end if;
 if a='join' then
  if c.phase<>'creating' then raise exception '학생 등록 단계가 아닙니다.';end if;
  v_name:=trim(coalesce(p->>'name',''));v_team:=p->>'team';
  if length(v_name)<1 or length(v_name)>30 or v_team not in ('경상도','전라도','충청도','제주도·강원도') then raise exception '이름과 팀을 확인하세요.';end if;
  if exists(select 1 from public.quiz_students where class_id=c.id and name=v_name) then raise exception '이미 등록된 이름입니다. 기존 기기에서 입장하세요.';end if;
  v_token:=encode(gen_random_bytes(32),'hex');
  insert into public.quiz_students(class_id,name,team,secret_hash) values(c.id,v_name,v_team,encode(digest(v_token,'sha256'),'hex')) returning * into s;
  return jsonb_build_object('id',s.id,'name',s.name,'team',s.team,'token',v_token);
 end if;
 if a='state' then
  -- 읽기 전용: 만료된 문제는 'available'로 계산하되, 실제 변경은 claim 단계에서 수행.
  select coalesce(jsonb_agg(jsonb_build_object('id',st.id,'name',st.name,'team',st.team) order by st.created_at),'[]'::jsonb) into v_out from public.quiz_students st where st.class_id=c.id;
  select coalesce(jsonb_agg(jsonb_build_object('id',qq.id,'authorId',qq.author_id,'team',qq.team,'body',qq.body,'options',qq.options,'correct',case when v_teacher or c.phase='finished' then qq.correct else null end,'status',case when qq.status='claimed' and qq.claimed_at<now()-interval '90 seconds' then 'available' else qq.status end,'answeredBy',qq.answered_by) order by qq.created_at),'[]'::jsonb) into v_attempts from public.quiz_questions qq where qq.class_id=c.id;
  return jsonb_build_object('classroom',jsonb_build_object('code',c.code,'name',c.name,'phase',c.phase),'students',v_out,'questions',v_attempts);
 end if;
 if a in ('phase','history','edit','delete','resetScores','resetAll') and not v_teacher then raise exception '교사 인증이 필요합니다.';end if;
 if a='phase' then
  if p->>'phase' not in ('creating','review','playing','finished') then raise exception '단계가 올바르지 않습니다.';end if;
  update public.quiz_classes set phase=p->>'phase' where id=c.id;return jsonb_build_object('ok',true);
 end if;
 if a='history' then
  select coalesce(jsonb_agg(jsonb_build_object('student',st.name,'question',qq.body,'choice',at.choice,'correct',at.correct,'wasCorrect',at.was_correct,'time',at.created_at) order by at.created_at desc),'[]'::jsonb) into v_out from public.quiz_attempts at join public.quiz_students st on st.id=at.student_id join public.quiz_questions qq on qq.id=at.question_id where at.class_id=c.id;
  return v_out;
 end if;
 if a='question' then
  if not v_student then raise exception '학생 인증이 필요합니다.';end if;
  if c.phase<>'creating' then raise exception '문제 제작 단계가 아닙니다.';end if;
  if (select count(*) from public.quiz_questions where author_id=s.id)>=4 then raise exception '문제는 학생당 4개까지 만들 수 있습니다.';end if;
  v_options:=p->'options';
  if length(trim(coalesce(p->>'body','')))<2 or jsonb_typeof(v_options)<>'array' or jsonb_array_length(v_options)<>4 or exists(select 1 from jsonb_array_elements_text(v_options) t where length(trim(t))=0) or coalesce((p->>'correct')::int,0) not between 1 and 4 then raise exception '문제, 보기 4개, 정답 번호를 확인하세요.';end if;
  insert into public.quiz_questions(class_id,author_id,team,body,options,correct) values(c.id,s.id,s.team,trim(p->>'body'),v_options,(p->>'correct')::int);
  return jsonb_build_object('ok',true);
 end if;
 if a in ('edit','delete') then
  select * into q from public.quiz_questions where id=(p->>'questionId')::uuid and class_id=c.id;
  if not found then raise exception '문제를 찾을 수 없습니다.';end if;
  if c.phase='playing' then raise exception '진행 중에는 문제를 수정할 수 없습니다.';end if;
  if a='delete' then delete from public.quiz_questions where id=q.id;else
   v_options:=p->'options';
   if length(trim(coalesce(p->>'body','')))<2 or jsonb_typeof(v_options)<>'array' or jsonb_array_length(v_options)<>4 or coalesce((p->>'correct')::int,0) not between 1 and 4 then raise exception '문제와 정답을 확인하세요.';end if;
   update public.quiz_questions set body=trim(p->>'body'),options=v_options,correct=(p->>'correct')::int where id=q.id;
  end if;
  return jsonb_build_object('ok',true);
 end if;
 if a='claim' then
  if not v_student then raise exception '학생 인증이 필요합니다.';end if;
  if c.phase<>'playing' then raise exception '대항전 진행 중이 아닙니다.';end if;
  v_team:=p->>'team';if v_team=s.team then raise exception '자기 팀 문제는 풀 수 없습니다.';end if;
  update public.quiz_questions set status='available',claimed_by=null,claimed_at=null where class_id=c.id and status='claimed' and claimed_at<now()-interval '90 seconds';
  select * into q from public.quiz_questions where class_id=c.id and team=v_team and status='available' and not exists(select 1 from public.quiz_attempts at where at.question_id=quiz_questions.id and at.student_id=s.id) order by random() for update skip locked limit 1;
  if not found then raise exception '지금 풀 수 있는 문제가 없습니다.';end if;
  update public.quiz_questions set status='claimed',claimed_by=s.id,claimed_at=now() where id=q.id;
  return jsonb_build_object('id',q.id,'body',q.body,'options',q.options,'team',q.team);
 end if;
 if a='answer' then
  if not v_student then raise exception '학생 인증이 필요합니다.';end if;
  if c.phase<>'playing' then raise exception '대항전 진행 중이 아닙니다.';end if;
  select * into q from public.quiz_questions where id=(p->>'questionId')::uuid and class_id=c.id for update;
  if not found or q.status<>'claimed' or q.claimed_by is distinct from s.id or q.claimed_at<now()-interval '90 seconds' then raise exception '문제 풀이 시간이 만료되었습니다.';end if;
  v_choice:=(p->>'choice')::int;if v_choice not between 1 and 4 then raise exception '보기를 선택하세요.';end if;
  insert into public.quiz_attempts(class_id,question_id,student_id,choice,correct,was_correct) values(c.id,q.id,s.id,v_choice,q.correct,v_choice=q.correct);
  if v_choice=q.correct then update public.quiz_questions set status='answered',answered_by=s.id,claimed_by=null,claimed_at=null where id=q.id;
  else update public.quiz_questions set status='available',claimed_by=null,claimed_at=null where id=q.id;end if;
  return jsonb_build_object('correct',v_choice=q.correct);
 end if;
 if a='resetScores' then
  delete from public.quiz_attempts where class_id=c.id;update public.quiz_questions set status='available',claimed_by=null,claimed_at=null,answered_by=null where class_id=c.id;update public.quiz_classes set phase='playing' where id=c.id;return jsonb_build_object('ok',true);
 end if;
 if a='resetAll' then
  delete from public.quiz_attempts where class_id=c.id;delete from public.quiz_questions where class_id=c.id;delete from public.quiz_students where class_id=c.id;update public.quiz_classes set phase='creating' where id=c.id;return jsonb_build_object('ok',true);
 end if;
 raise exception '알 수 없는 요청입니다.';
end $$;
revoke all on function public.quiz_api(jsonb) from public;grant execute on function public.quiz_api(jsonb) to anon,authenticated;
