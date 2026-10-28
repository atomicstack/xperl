---
name: tmux-agent-status
description: Show agent activity and input waits through tmux tab colours and a matching terminal-title symbol when working in the user's tmux session.
---

# Agent status in tmux

This workspace uses a visible status indicator for the primary agent and its
subagents. It reports activity and input waits, not test success.

## Status and priority

| State | Window style | Terminal-title symbol |
|---|---|---|
| Either agent needs user input or approval | `fg=black,bg=colour214,bold` | Orange circle |
| Working | Alternate `fg=black,bg=cyan` and `fg=black,bg=green` | Blue or green circle |
| All agents idle | Restore the original window styles | White circle |

Amber overrides the activity counter, including when another agent continues
working. Set amber before asking a question or requesting required approval
where possible. An automatic approval prompt can block before a status
command runs; do not claim that every such prompt can be signalled.

Clear amber when the user supplies the needed input or explicitly clears
the wait. Resume working colour immediately. Receiving unrelated input does
not resolve a pending question. Ending a progress update or waiting for a
subagent does not itself mean user input is needed.

Count ordinary tool operations, including reads, edits, commands, job launches,
and polls. After every **five operations**, alternate cyan and green. Do not
count status-update commands. Do not alternate while amber is active.
Each agent maintains its own counter. The primary agent coordinates shared
state: one agent must not clear another agent's unresolved input wait, and
normal colour requires all agents to be idle.

Use the shared window option `@agent_status_waiting_for_user` as a latch.
Set it to `1` before requesting attention, including technical sandbox
approvals. When claiming an unset latch, record the requesting agent in
`@agent_status_wait_owner`. Do not take ownership of an existing wait.
Set both styles amber and notify the primary agent. Subagents
must relay their question or approval request to the primary conversation
so the user does not have to open a subagent view to discover it.

Before every activity-colour update, read the shared option and leave the
colour unchanged if it is `1`. This applies even when that agent has no
question of its own. Clear the latch to `0` only after all outstanding
requests are answered or the user explicitly clears the wait, then restore
working colour immediately. Do not treat a successful operation counter
tick as permission to clear the latch.

The requesting agent must clear its own completed technical-approval wait
immediately after the tool returns or the command starts, provided no other
request is pending. This includes commands that proceed without an approval
prompt. Notify the primary agent, but do not wait for it to execute the colour
change: its turn may have ended. Never clear a wait owned by another agent.
Do not keep amber through a running build merely because approval was needed,
and do not ask the user to clear a wait that has already resolved.

For example, before an attention request:

```sh
tmux set-window-option -t "$status_window_id" @agent_status_wait_owner "$status_agent_name"
tmux set-window-option -t "$status_window_id" @agent_status_waiting_for_user 1
tmux set-window-option -t "$status_window_id" window-status-style 'fg=black,bg=colour214,bold'
tmux set-window-option -t "$status_window_id" window-status-current-style 'fg=black,bg=colour214,bold'
tmux refresh-client -S
```

## Discover and retain the target

Capture the agent's window ID at the start, using its known pane rather than
whichever window the user later selects:

```sh
tmux display-message -p -t "$TMUX_PANE" '#{window_id} #{session_id}'
```

If `TMUX_PANE` is unavailable, inspect the session and identify the agent's
pane before choosing a target. Retain the resulting window and session IDs,
and pass the same target to subagents. Do not hardcode `@0`, a session name,
or a window index in reusable instructions.

Record the window's local `window-status-style` and
`window-status-current-style` before overriding them. When all agents become
idle, restore those values, or unset overrides that were originally inherited.

Set both styles so the status is visible when the tab is selected or not:

```sh
tmux set-window-option -t "$status_window_id" window-status-style 'fg=black,bg=cyan'
tmux set-window-option -t "$status_window_id" window-status-current-style 'fg=black,bg=cyan'
tmux refresh-client -S
```

Use the same commands with the other state styles. Coordinate writes with
the primary agent. Before an activity toggle, check that no input wait is
active and that the window has not been marked amber by another agent.

## Terminal title

The user also wants a coloured circle in the terminal application's tab
title. Configure tmux `set-titles` for the relevant session, not globally.
Derive the symbol from the active window's style so both agents' existing
colour updates change it automatically.

There is no cyan-circle emoji. Blue is the agreed approximation for cyan.
This changes the title text; it does not control the terminal tab's overall
text or background colour. In GNOME Terminal, emoji colour comes from the
font. Keep the session, window index, and window name visible after the dot.

The following setup uses ASCII source escapes for the title symbols:

```sh
status_amber_dot=$(printf '\360\237\237\240')
status_green_dot=$(printf '\360\237\237\242')
status_blue_dot=$(printf '\360\237\224\265')
status_idle_dot=$(printf '\342\232\252')
status_title_format='#{?#{m:*colour214*,#{window-status-style}},'"$status_amber_dot"',#{?#{m:*bg=green*,#{window-status-style}},'"$status_green_dot"',#{?#{m:*bg=cyan*,#{window-status-style}},'"$status_blue_dot"','"$status_idle_dot"'}}} #{session_name}:#{window_index} #{window_name}'
tmux set-option -t "$status_session_id" set-titles-string "$status_title_format"
tmux set-option -t "$status_session_id" set-titles on
```

Preserve an existing status-title setup rather than repeatedly replacing it.
Verify the expanded title with `tmux display-message -p -t` and the captured
window target, using the format `#{T:set-titles-string}`.

## Command execution and authorization

Invoke `tmux` directly. Avoid unnecessary `bash -lc` wrappers that can make
approved commands appear as different approval requests. Reuse an approved
`tmux` prefix where available. A socket restriction can still require genuine
escalation; follow the tool's permission rules rather than bypassing them.
Do not ask the user to reauthorize routine work already covered by the task.

Status commands run directly and do not need a dedicated pane. Use a visible,
reused tmux work window for long builds, Configure runs, and test harnesses.
Run short reads, edits, and lightweight scripts directly. Do not send work
into a pane occupied by the user or another running job.
