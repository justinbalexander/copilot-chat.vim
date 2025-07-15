scriptencoding utf-8

let s:curl_output = []

function! copilot_chat#api#async_request(messages, file_list) abort
  let l:chat_token = copilot_chat#auth#verify_signin()
  let s:curl_output = []
  let l:url = 'https://api.githubcopilot.com/chat/completions'

  " for knowledge bases its just an attachment as the content
  "{'content': '<attachment id="kb:Name">\n#kb:\n</attachment>', 'role': 'user'}
  " for files similar
  for file in a:file_list
    let l:file_content = readfile(file)
    let full_path = fnamemodify(file, ':p')
    " TODO: get the filetype instead of just markdown
    let l:c = '<attachment id="' . file . '">\n````markdown\n<!-- filepath: ' . full_path . ' -->\n' . join(l:file_content, "\n") . '\n```</attachment>'
    call add(a:messages, {'content': l:c, 'role': 'user'})
  endfor

  let l:data = json_encode({
        \ 'intent': v:false,
        \ 'model': copilot_chat#models#current(),
        \ 'temperature': 0,
        \ 'top_p': 1,
        \ 'n': 1,
        \ 'stream': v:true,
        \ 'messages': a:messages
        \ })
  let l:temp_file = tempname()
  echomsg l:temp_file
  call writefile([l:data], l:temp_file)

  let l:curl_cmd = [
        \ 'curl',
        \ '-s',
        \ '-X',
        \ 'POST',
        \ '-H',
        \ 'Content-Type: application/json',
        \ '-H', 'Authorization: Bearer ' . l:chat_token,
        \ '-H', 'Editor-Version: vscode/1.80.1',
        \ '-d',
        \ '@'.l:temp_file,
        \ l:url]

  if has('nvim')
    let job = jobstart(l:curl_cmd, {
      \ 'on_stdout': {chan_id, data, name->copilot_chat#api#handle_job_output(chan_id, data)},
      \ 'on_exit': {chan_id, data, name->copilot_chat#api#handle_job_close(chan_id, data)},
      \ 'on_stderr': {chan_id, data, name->copilot_chat#api#handle_job_error(chan_id, data)},
      \ 'stdout_buffered': v:true,
      \ 'stderr_buffered': v:true
      \ })
  else
    let job = job_start(l:curl_cmd, {
      \ 'out_cb': function('copilot_chat#api#handle_job_output'),
      \ 'exit_cb': function('copilot_chat#api#handle_job_close'),
      \ 'err_cb': function('copilot_chat#api#handle_job_error')
      \ })
  endif
  call copilot_chat#buffer#waiting_for_response()

  return job
endfunction

function! copilot_chat#api#handle_job_output(channel, msg) abort
  if type(a:msg) == v:t_list
    for data in a:msg
      if data =~? '^data: {'
        call add(s:curl_output, data)
      endif
    endfor
  else
    call add(s:curl_output, a:msg)
  endif
endfunction

function! copilot_chat#api#apply_code_change(filename, vimcmd, code) abort
  " Open the file in the background
  execute 'silent split'
  execute 'silent find' fnameescape(a:filename)
  " Replace <CR> with \r for :normal
  let normcmd = substitute(a:vimcmd, '<CR>', "\r", 'g')
  if normcmd =~ a:vimcmd
    echoerr "LLM did not output <CR> for filename and vimcmd:".a:filename.":".a:vimcmd
  endif
  " Execute the normal command to select the code
  " Disabling auto indenting and such temporarily
  execute 'let l:magic_state = &magic'
  execute 'silent! setlocal magic'
  execute 'silent! setlocal paste'
  execute 'silent normal! gg' . normcmd . a:code
  execute 'silent! setlocal nopaste'
  execute 'let &magic = l:magic_state'
  " Write changes to the file
  execute 'silent! update' fnameescape(a:filename)
  " Close the window
  execute 'silent! close'
endfunction

" Process the llm output to search for new instructions to be
" executed
function! copilot_chat#api#process_llm_output(llm_output) abort
  let parse_state = "code_search"
  " code_search
  " consume_code_block

  " Declare variables that need to persist through multiple lines of
  " parsed llm_output
  let filename = ""
  let vimcmd = ""
  let code = ""

  for line in a:llm_output
    if parse_state == "consume_code_block"
      if line =~ '^```$'
        " Found end of block, go back to searching for the next code block
        " after dealing with the latest find
        let parse_state = "code_search"
        " There's always an extra return appended. Delete it.
        let code = substitute(code, '\r$', '', '')
        call copilot_chat#api#apply_code_change(filename, vimcmd, code)

        " Reset all persistent variables
        let filename = ""
        let vimcmd = ""
        let code = ""
        continue
      else
        " Collecting the text because we haven't found the end of the block
        " The newline gets stripped so I want to add it back so it's exactly
        " as 'typed' by the llm
        let code .= line."\r"
      endif
    elseif parse_state == "code_search"
      " Searching for a new code block, do we find one that matches the
      " pattern we are expecting?
      " Pattern:```filetype /path/to/file:vimnormalcommands
      " Note the \{-} makes the match non-greedy otherwise vim commands
      " with a colon in them get pulled into the filename
      let header = matchlist(line, '^```[a-zA-Z0-9_+-]*\s\+\(\S\{-}\):\(.*\)$')
      if !empty(header)
        " We found a code block, parse out the contents, spread over multiple
        " lines
        let parse_state = "consume_code_block"

        let filename = header[1]
        let vimcmd = header[2]
      endif
    endif
  endfor
endfunction

function! copilot_chat#api#handle_job_close(channel, msg) abort
  call deletebufline(g:copilot_chat_active_buffer, '$')
  let l:result = ''
  for line in s:curl_output
    if line =~? '^data: {'
      let l:json_completion = json_decode(line[6:])
      try
        let l:content = l:json_completion.choices[0].delta.content
        if type(l:content) != type(v:null)
          let l:result .= l:content
        endif
      catch
        let l:result .= "\n"
      endtry
    endif
  endfor

  let l:width = winwidth(0) - 2 - getwininfo(win_getid())[0].textoff
  let l:separator = ' '
  let l:separator .= repeat('━', l:width)
  call copilot_chat#buffer#append_message(l:separator)
  call copilot_chat#buffer#append_message(split(l:result, "\n"))
  call copilot_chat#buffer#add_input_separator()

  call copilot_chat#api#process_llm_output(split(l:result, "\n"))
endfunction

function! copilot_chat#api#handle_job_error(channel, msg) abort
  if type(a:msg) == v:t_list
    let l:filtered_errors = filter(copy(a:msg), '!empty(v:val)')
    if len(l:filtered_errors) > 0
      echom l:filtered_errors
    endif
  else
    echom a:msg
  endif
endfunction

function! copilot_chat#api#fetch_models(chat_token) abort
  let l:chat_headers = [
    \ 'Content-Type: application/json',
    \ 'Authorization: Bearer ' . a:chat_token,
    \ 'Editor-Version: vscode/1.80.1'
    \ ]

  let l:response = copilot_chat#http('GET', 'https://api.githubcopilot.com/models', l:chat_headers, {})
  try
    let l:json_response = json_decode(l:response)
    let l:model_list = []
    for item in l:json_response.data
        if has_key(item, 'id')
            call add(l:model_list, item.id)
        endif
    endfor
    return l:model_list
  endtry

  return l:response
endfunction

" vim:set ft=vim sw=2 sts=2 et:
