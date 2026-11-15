;===============================================================================
;  WIZARD OF WOR - Porting 6809 (LWASM) per Olivetti Prodest PC 128 / Thomson MO6
;  VERSIONE FINALE: 2 Giocatori (P1+P2), Musica Polifonica C64 e Suoni DCMOTO
;
;  Build:  lwasm --decb -o wizard_of_wor.bin wizard_of_wor_m2_title.asm
;
;  Modello labirinto (ricavato dal disassemblato C64 di dabadab, draw_dungeon):
;    - griglia 11 colonne x 6 righe; ogni cella = maschera dei muri sui suoi lati
;      W=1 N=2 E=4 S=8 (muro definito su entrambe le celle adiacenti)
;    - 25 layout da 18 byte (6x6 nibble, meta' sinistra); la meta' destra e' lo
;      specchio con W<->E scambiati (colonna 5 = centro)
;    - bordo esterno chiuso, tranne le porte warp sui lati della riga 2
;    - scelta del layout come sul C64: dungeon 4 = Arena (24), 1-7 casuali 0..14,
;      poi 15..22 casuali, ogni 6 il Pit (23); mai lo stesso layout due volte
;
;  MOVIMENTO FLUIDO: ogni cella ha 7 sotto-passi in x e 6 in y.
;    posizione = cella (actor_x/y) + sotto-passo (actor_sx 0..6, actor_sy 0..5)
;    1 sotto-passo = 2 px in x (4 unita' schermo) e 4 px in y (4 unita'): velocita'
;    uniforme. Il controllo muri si fa solo sul confine di cella (sotto-passo 0);
;    a meta' cella si puo' proseguire o invertire. Si svolta solo da allineati
;    (su un tratto orizzontale non si va in verticale e viceversa); se il giocatore
;    chiede una svolta a meta' cella, prosegue fino al confine piu' vicino.
;    Pallottole: stesso meccanismo, BULLET_STEPS sotto-passi per frame.
;    Lo stesso step_move serve ad attori e proiettili (passando per variabili m_*).
;
;  SPRITE (v1.2): 12x18 px (= 24x18 unita' schermo, stessa proporzione dell'originale
;    C64 24x18), ridotti dal disassemblato C64 da wow_sprites.py. 3 fotogrammi per
;    direzione; sinistra/destra e basso derivati per specchio. Lo sprite e' opaco
;    (sfondo nero compreso) e viene disegnato con il colore del tipo di attore.
;    blit_sprite decodifica 18 righe in un buffer di coppie di pixel e le scrive nei
;    due banchi (A/B), valido per x pari con qualsiasi parita' di colonna-coppia.
;
;  Grafica bitmap16 (160x200): banchi A/B, x e larghezze PARI (vedi v3).
;
;  REGOLE E FUNZIONALITA' COMPLETE (fedeli al disassemblato C64):
;    - 1 o 2 giocatori simultanei (P1 giallo a destra, P2 verde a sinistra):
;      P1: Joystick 0 oppure Frecce + Spazio/Invio/1
;      P2: Joystick 1 oppure WASD/ZQSD + Ctrl/X/2
;      Fuoco P1 nella schermata titolo avvia 1P; Fuoco P2 avvia 2P.
;    - Audio DCMOTO nativo (DAC 6-bit su $A7CD + Buzzer 1-bit su $A7C1, mute $A7C0 bit2=0):
;      * Jingle polifonici C64 a 3 voci (Sawtooth + 2 Pulse + vibrato SID esatto)
;        per GET READY / GO, DOUBLE SCORE DUNGEON e GAME OVER.
;      * Basso ostinato C64 a 3 note durante il gioco con accelerazione progressiva.
;      * Tutti i 12 effetti sonori C64 (spari, esplosioni, porte warp, Worluk, Wizard).
;===============================================================================

;-------------------------------------------------------------------------------
; Costanti di gioco
;-------------------------------------------------------------------------------
MAX_ACTORS      EQU 8
PLAYER1         EQU $02
PLAYER2         EQU $01
BURWOR          EQU $03
DEAD            EQU $FF

DIR_LEFT        EQU $FF
DIR_RIGHT       EQU 1
DIR_UP          EQU $FF
DIR_DOWN        EQU 1

MAZE_W          EQU 11
MAZE_H          EQU 6
WALL_W          EQU 1                   ; bit maschera muri
WALL_N          EQU 2
WALL_E          EQU 4
WALL_S          EQU 8

SUBSTEPS_X      EQU 7                   ; sotto-passi per cella in orizzontale
SUBSTEPS_Y      EQU 6                   ; ... e in verticale
SCORE_KILL      EQU 100
PLAYER_STEPS    EQU 1                   ; sotto-passi per frame del giocatore
BULLET_STEPS    EQU 2                   ; sotto-passi per frame delle pallottole
GARWOR          EQU 4
THORWOR         EQU 5
WORLUK          EQU 7
WIZARD          EQU 8
SEC_TICKS       EQU 50                  ; tick IRQ (50 Hz) per secondo di gioco
FRAME_TICKS     EQU 2                   ; un frame logico = 2 tick IRQ (25 Hz, con DAC continuo)
SIM_HZ          EQU 14                  ; passi di simulazione al secondo: velocita' esatta C64 (~2,08 celle/s)
MUS_ATT         EQU 3                   ; attenuazione extra del basso di sottofondo (SN76489)
WF_TIMEOUT      EQU 1200                 ; cicli max in wait_frame (con dac_step) se l'IRQ non arriva
IRQ_VEC         EQU $2061               ; vettore del task di interrupt del monitor MO6
DYING_FRAMES    EQU 20                  ; durata esplosione (~1,4 s come sul C64)
INVUL_FRAMES    EQU 28                  ; protezione dopo la rinascita (~2 s)
WARP_FRAMES     EQU 56                  ; porta warp chiusa dopo un teleport (~4 s)
WORLUK_WAIT     EQU 56                  ; porte chiuse all'arrivo di Worluk (~4 s)
ONCE_RELOAD     EQU 64                  ; azioni tra due 'puntamenti al giocatore'
MON_BULLET_STEPS EQU 1                  ; sotto-passi/frame delle pallottole dei mostri
HEAD_SUB        EQU 2                   ; la testa del mostro e' 2 sotto-passi avanti
HIT_R2          EQU 2                   ; raggio della testa contro il giocatore
ALIGN_R         EQU 5                   ; 'stessa riga/colonna' (sotto-passi)
START_LIVES     EQU 2                   ; vite extra iniziali
PEND_NEXT       EQU 1
PEND_WORLUK     EQU 2
PEND_WIZARD     EQU 3
PEND_OVER       EQU 4
SPR_LIFE        EQU 0                   ; id sprite vite extra P1 (guarda a sinistra, come sul C64)
SPR_LIFE_P2     EQU 3                   ; id sprite vite extra P2 (guarda a destra, come sul C64)
SPR_BOOM        EQU 54                  ; id primo fotogramma esplosione
LIVES_X         EQU 108                 ; vite di P1: a destra del radar
LIVES2_X        EQU 4                   ; vite di P2: a sinistra del radar
LIVES_Y         EQU 155                 ; y = 155..172 (sotto: punteggi a riga 22, y=176..190)
RADAR_X         EQU 58                  ; radar centrato: riquadro 48 px = x 56..103
RADAR_Y         EQU 160
RADAR_PX        EQU 4                   ; passo per cella: 4 px in x (2 px di punto + 2 di vuoto)
RADAR_PY        EQU 5                   ; ... 5 righe in y (4 di punto + 1 di vuoto)
RADAR_DW        EQU 2                   ; punto 2 x 4 px (~quadrato con pixel 2:1)
RADAR_DH        EQU 4
RADAR_W         EQU MAZE_W*RADAR_PX     ; 44
RADAR_H         EQU MAZE_H*RADAR_PY     ; 30
HIT_R           EQU 3                   ; raggio di collisione (sotto-passi)

;-------------------------------------------------------------------------------
; Indirizzi programma / stack
;-------------------------------------------------------------------------------
PROG_ORG        EQU $3400
STACK_TOP       EQU $7FF0

;-------------------------------------------------------------------------------
; HARDWARE MO6 / PC128 / MO5 (DCMOTO)
;-------------------------------------------------------------------------------
SYS_PIA_A       EQU $A7C0               ; bit0=banco VRAM, bit2=mute DAC (0=ON), bit3=tastiera MO6
SYS_PIA_B       EQU $A7C1               ; bit0=buzzer 1-bit, bit1-6=selettore tasti, bit7=stato tasto
GA_MODE         EQU $A7DC               ; gate array: modo video
BM16_MODE       EQU $7B                 ; bitmap16 160x200x16
PAL_IDX         EQU $A7DB
PAL_DATA        EQU $A7DA
JOY_PRA         EQU $A7CC               ; bit0-3=Joy0 (P1), bit4-7=Joy1 (P2) (attivi bassi)
JOY_PRB         EQU $A7CD               ; bit0-5=DAC 6-bit (uscita), bit6=Fire0, bit7=Fire1
JOY_CRA         EQU $A7CE               ; controllo PIA musica/giochi porta A
JOY_CRB         EQU $A7CF               ; controllo PIA musica/giochi porta B
JOY_B_UP        EQU $01
JOY_B_DOWN      EQU $02
JOY_B_LEFT      EQU $04
JOY_B_RIGHT     EQU $08
JOY_B_FIRE      EQU $40
JOY2_B_UP       EQU $10
JOY2_B_DOWN     EQU $20
JOY2_B_LEFT     EQU $40
JOY2_B_RIGHT    EQU $80
JOY2_B_FIRE     EQU $80
SN_PORT         EQU $A7FF               ; porta scheda audio SN76489 (espansione audio)

VRAM            EQU $0000
VRAM_STRIDE     EQU 40
VRAM_BANK_SIZE  EQU 8000

;-------------------------------------------------------------------------------
; Geometria (x e larghezze sempre PARI)
;-------------------------------------------------------------------------------
CELL_W          EQU 14                  ; = SUBSTEPS_X * 2 px
CELL_H          EQU 24                  ; = SUBSTEPS_Y * 4 px
MAZE_OX         EQU 2                   ; 2 + 11*14 + 2 = 158 (<160)
MAZE_OY         EQU 4                   ; 4 + 6*24 + 4 = 152 (HUD sotto, T3)
BAR_W           EQU 2                   ; spessore linee verticali (px)
BAR_H           EQU 4                   ; spessore linee orizzontali (righe)
ACT_W           EQU 12                  ; sprite 12x18 px
ACT_H           EQU 18
ACT_OX          EQU 2                   ; spessore barra: lo sprite occupa l'interno 12x20
ACT_OY          EQU 5                   ; 4 (barra) + 1 di margine
BUL_W           EQU 2
BUL_H           EQU 4
BUL_OX          EQU 6
BUL_OY          EQU 12

COL_FLOOR       EQU 0
COL_WALL        EQU 2	
COL_P1          EQU 2
COL_P2          EQU 3
COL_BURWOR      EQU 4
COL_GARWOR      EQU 5
COL_THORWOR     EQU 6
COL_WORLUK      EQU 7
COL_BULLET      EQU 8
COL_WIZARD      EQU 9
COL_BOOM        EQU 2
COL_MBULLET     EQU 6

;===============================================================================
; CODICE
;===============================================================================
                ORG PROG_ORG

start
                ORCC #$50
                LDS #STACK_TOP
                JSR init_hardware
                JSR snd_init
                JSR install_irq
                ANDCC #$EF                  ; abilita IRQ (start li aveva mascherati): senza, irq_tick/snd_tick non girano mai
                JSR init_game
                JSR hs_clear
                JSR title_screen            ; attract mode: fino alla pressione del fuoco
                JSR new_game
                JSR start_dungeon

main_loop
                JSR wait_frame
                JSR read_joystick
                JSR handle_input
                JSR run_sim                 ; passi di simulazione dovuti (tempo reale, non fps)
                JSR check_events
                LDA sim_n
                BEQ main_loop               ; nessun passo simulato: dedica l'intero frame al DAC audio
                JSR draw_all
                BRA main_loop

; run_sim: esegue sim_n passi di gioco (calcolati da wait_frame in base ai tick trascorsi):
; la velocita' di giocatori, mostri e pallottole non dipende piu' dal tempo di disegno
run_sim
                LDB sim_n
                BEQ rs_end
rs_lp           PSHS B
                JSR update_actors
                JSR update_bullets
                JSR check_hits
                PULS B
                DECB
                BNE rs_lp
rs_end          RTS

;-------------------------------------------------------------------------------
; Hardware
;-------------------------------------------------------------------------------
init_hardware
                LDB #$14                    ; (aggiunta di Dino) chiamata di sistema SWI/$02 con B=$14
                SWI
                FCB $02
                LDA $A7E4                   ; colore del bordo
                ANDA #$F0
                STA $A7DD
                LDA SYS_PIA_A
                ANDA #$E0                   ; bit2 = 0 (sblocca mute audio su MO6/PC128)
                ORA #$09                    ; bit0 = 1 (banco A), bit3 = 1 (abilita righe 0-7 tastiera MO6)
                STA sys_a
                STA SYS_PIA_A
                LDA $A7C3                   ; assicura che l'IRQ timer/VSync a 50 Hz sia abilitato
                ORA #$01
                STA $A7C3
                LDA #BM16_MODE
                STA GA_MODE
                CLR PAL_IDX
                LDX #palette_data
                LDB #32
ih_pal          LDA ,X+
                STA PAL_DATA
                DECB
                BNE ih_pal
                BSR clear_screen
                RTS

clear_screen
                JSR sel_bank_a
                BSR cs_bank
                JSR sel_bank_b
cs_bank         LDX #VRAM
cs_lp           CLR ,X+
                CMPX #VRAM+VRAM_BANK_SIZE
                BNE cs_lp
                RTS

; clear_maze_area: pulisce l'area del labirinto (y = 0..151 = 6080 byte) lasciando intatto l'HUD
clear_maze_area
                JSR sel_bank_a
                BSR cma_bank
                JSR sel_bank_b
cma_bank        LDX #VRAM
cma_lp          CLR ,X+
                CMPX #VRAM+6080
                BNE cma_lp
                RTS

sel_bank_a      LDA sys_a
                ORA #$01
                BRA sb_set
sel_bank_b      LDA sys_a
                ANDA #$FE
sb_set          STA sys_a
                STA SYS_PIA_A
                RTS

;-------------------------------------------------------------------------------
; Inizializzazione e dungeon
;-------------------------------------------------------------------------------
init_game
                LDA #$A5
                STA rnd
                CLR two_players
                CLR wall_col_st
new_game
                LDA #$FF
                STA current_dungeon         ; il primo INC porta a 0
                STA prev_layout
                CLR phase
                CLR score
                CLR score+1
                CLR score2
                CLR score2+1
                CLR want_x
                CLR want_x+1
                CLR want_y
                CLR want_y+1
                CLR dbl_next
                LDA #START_LIVES
                STA lives
                LDA two_players
                BNE ng_2p
                LDA #$FF
                STA lives2
                RTS
ng_2p           LDA #START_LIVES
                STA lives2
                RTS

; clear_msg_box: pulisce il riquadro centrale dei messaggi (x=32..127, y=36..115) lasciando visibile la cornice del labirinto
clear_msg_box
                CLR draw_color
                LDA #32
                STA px_x
                LDA #36
                STA px_y
                LDA #96
                STA rect_w
                LDA #80
                STA rect_h
                JMP fill_rect

; Nuovo dungeon: sequenza C64 fedele (labirinto visibile sullo sfondo + DOUBLE SCORE / GET READY / GO + jingle SID a 3 voci)
start_dungeon
                JSR snd_silence
                CLR wall_col_st
                CLR PAL_IDX                 ; ripristina sfondo nero (0) e muri blu (1)
                CLR PAL_DATA
                CLR PAL_DATA
                LDA #$00
                STA PAL_DATA
                LDA #$0C
                STA PAL_DATA
                JSR select_layout           ; A = indice layout 0..24
                JSR expand_layout
                JSR clear_screen
                JSR setup_rules
                JSR reset_actors
                JSR draw_maze               ; disegna subito il labirinto sullo sfondo (come draw_dungeon sul C64)
                JSR draw_lives
                JSR draw_radar_box
                JSR draw_hud_scores
                ; Se dungeon a punteggio doppio o vita bonus (dungeon 4 Arena / 13 Pit):
                LDA dbl_active
                BNE sd_dbl
                LDA current_dungeon
                CMPA #3
                BEQ sd_bon_only
                CMPA #12
                BNE sd_gr
sd_bon_only     JSR clear_msg_box
                LDX #tx_bonus
                JSR draw_text
                BRA sd_p2jg
sd_dbl          JSR clear_msg_box
                LDX #tx_dbl1
                JSR draw_text
                LDX #tx_dbl2
                JSR draw_text
                LDA current_dungeon
                CMPA #3
                BEQ sd_dbl_b
                CMPA #12
                BNE sd_p2jg
sd_dbl_b        LDX #tx_bonus
                JSR draw_text
sd_p2jg         LDX #snd_pattern_2          ; jingle C64 "DOUBLE SCORE DUNGEON"
                JSR jg_play
sd_gr           JSR clear_msg_box
                LDX #tx_dng                 ; "DUNGEON N"
                JSR draw_text
                LDA #COL_BURWOR
                STA nm_color
                LDA #5
                STA nm_row
                LDA #20
                STA nm_col
                LDB current_dungeon
                INCB
                CLRA
                JSR draw_num
                LDX #tx_gr_mid              ; "GET READY"
                JSR draw_text
                LDX #snd_pat_1a             ; prima parte jingle C64 Get Ready
                JSR jg_play
                LDX #tx_go_mid              ; "GO"
                JSR draw_text
                LDX #snd_pat_1b             ; seconda parte jingle C64 Get Ready
                JSR jg_play
                JSR clear_maze_area
                JSR draw_maze
                JSR draw_actors
                JSR update_radar
                LDA #7                      ; SFX_PLAYER_LAUNCH
                JSR snd_play
                LDB #18                     ; fa sentire il lancio prima dell'azione
sd_wln          PSHS B
                JSR wait_frame
                PULS B
                DECB
                BNE sd_wln
                CLR sim_n
                CLR sim_acc
                JSR mus_start               ; parte il basso ostinato C64 di sottofondo
                RTS

; setup_rules: regole per dungeon (velocita', contatori, bonus)
setup_rules
                CLR phase
                CLR pending
                LDA dbl_next
                STA dbl_active              ; punteggio doppio solo in questo dungeon
                CLR dbl_next
                LDA #6
                STA burwors_alive
                LDA #5
                STA normal_left
                LDA #1
                STA warp_open
                CLR warp_timer
                LDA #ONCE_RELOAD
                STA once_timer
                LDA current_dungeon
                CMPA #8
                BLO sr_s
                LDA #7                      ; dungeon 9+: velocita' massima
sr_s            EORA #7
                STA cur_speed               ; 7 = lento ... 0 = veloce
                LDA current_dungeon
                CMPA #3                     ; Arena (dungeon 4)
                BEQ sr_bonus
                CMPA #12                    ; primo Pit (dungeon 13)
                BNE sr_nb
sr_bonus        LDA lives
                CMPA #$FF
                BEQ sr_bon2
                INC lives                   ; vita bonus P1
sr_bon2         LDA lives2
                CMPA #$FF
                BEQ sr_nb
                INC lives2                  ; vita bonus P2
sr_nb           RTS

; select_layout: stessa logica di select_dungeon_layout del C64.
select_layout
                INC current_dungeon
                LDA current_dungeon
                CMPA #$62                   ; dopo il dungeon 98 torna al 97
                BNE sl_again
                LDA #$60
                STA current_dungeon
sl_again        LDA current_dungeon
                CMPA #3
                BNE sl_not_arena
                LDA #24                     ; dungeon 4: Arena
                BRA sl_chosen
sl_not_arena    CMPA #7
                BHS sl_over8
sl_rnd          JSR random                  ; dungeon 1-7: layout casuale 0..14
                ANDA #$0F
                CMPA #$0F
                BEQ sl_rnd
                BRA sl_chosen
sl_over8        SUBA #6                     ; A = dungeon mod 6
                BHS sl_over8
                ADDA #6
                BNE sl_notpit
                LDA #23                     ; ogni 6 dungeon: il Pit
                BRA sl_chosen
sl_notpit       JSR random                  ; "worlord": layout casuale 15..22
                ANDA #7
                ADDA #15
sl_chosen       CMPA prev_layout            ; mai lo stesso layout due volte
                BEQ sl_again
                STA prev_layout
                RTS

; expand_layout: A = indice layout -> maze[66] (maschere W/N/E/S per cella)
expand_layout
                LDB #18
                MUL
                ADDD #layout_data
                TFR D,X                     ; X = sorgente (18 byte, 36 nibble)
                LDY #maze                   ; Y = cella sinistra corrente
                LEAU 10,Y                   ; U = cella speculare corrente
                LDA #MAZE_H
                STA el_rows
el_row          LDA #3                      ; 3 byte = 6 nibble per riga
                STA el_bytes
el_byte         LDB ,X+
                PSHS B
                LSRB
                LSRB
                LSRB
                LSRB                        ; nibble alto prima
                BSR el_put
                PULS B
                ANDB #$0F
                BSR el_put
                DEC el_bytes
                BNE el_byte
                LEAY 5,Y                    ; Y: da riga+6 a riga+11
                LEAU 17,U                   ; U: da riga+4 a riga+21 (= +11 +10)
                DEC el_rows
                BNE el_row
                RTS

; el_put: B = maschera -> maze[c] = B (Y+), maze[10-c] = specchio(B) (U-)
el_put          STB ,Y+
                PSHS X
                LDX #mirror_tbl
                LDA B,X
                PULS X
                STA ,U
                LEAU -1,U
                RTS

; reset_actors: tutti morti, P1 in basso a destra (10,5), P2 in basso a sinistra (0,5), 6 Burwor
reset_actors
                LDX #0
ra_lp           LDA #DEAD
                STA actor_type,X
                LDA #$FF
                STA prev_px,X               ; $FF = mai disegnato
                CLR prev_py,X
                CLR prev_bpx,X
                CLR prev_bpy,X
                CLR prev_firing,X
                CLR firing,X
                CLR actor_sx,X
                CLR actor_sy,X
                CLR actor_hx,X
                CLR actor_hy,X
                CLR actor_fx,X
                CLR actor_fy,X
                CLR actor_timer,X
                CLR actor_anim,X
                CLR actor_dying,X
                CLR actor_inv,X
                CLR actor_wx,X
                CLR actor_wy,X
                CLR actor_spd,X
                CLR actor_invt,X
                CLR actor_sec,X
                CLR bullet_dx,X
                CLR bullet_dy,X
                CLR bullet_sx,X
                CLR bullet_sy,X
                LEAX 1,X
                CMPX #MAX_ACTORS
                BNE ra_lp
                LDA #$FF
                STA pl_ax
                STA p2_ax
                LDA lives
                CMPA #$FF
                BEQ ra_chk2
                LDA #PLAYER1
                STA actor_type
                LDA #10
                STA actor_x
                LDA #5
                STA actor_y
                LDA #DIR_LEFT
                STA actor_fx
                LDA #10*SUBSTEPS_X
                STA pl_ax
                LDA #5*SUBSTEPS_Y
                STA pl_ay
                LDA #INVUL_FRAMES
                STA p_invul
ra_chk2         LDA lives2
                CMPA #$FF
                BEQ ra_mons
                LDA #PLAYER2
                STA actor_type+1
                CLR actor_x+1
                LDA #5
                STA actor_y+1
                LDA #DIR_RIGHT
                STA actor_fx+1
                CLR p2_ax
                LDA #5*SUBSTEPS_Y
                STA p2_ay
                LDA #INVUL_FRAMES
                STA p_invul+1
ra_mons         LDX #2
ra_mon          LDA #BURWOR
                STA actor_type,X
                JSR init_monster
                LEAX 1,X
                CMPX #MAX_ACTORS
                BNE ra_mon
                RTS

; init_monster: X = indice; posizione a caso (come spawn_monster), velocita' del dungeon
init_monster
                JSR spawn_monster
                LDA cur_speed
                STA actor_spd,X
                CLR actor_inv,X
                CLR actor_dying,X
                CLR actor_hx,X
                CLR actor_hy,X
                CLR actor_timer,X
                CLR actor_anim,X
                CLR firing,X
                LDA #DIR_LEFT
                STA actor_fx,X
                CLR actor_fy,X
                LDA #SEC_TICKS
                STA actor_sec,X
                JSR random
                ANDA #3
                ADDA #4                     ; 4..7 secondi alla prima invisibilita'
                STA actor_invt,X
                JSR rand_want
                RTS

; spawn_monster: X = indice; cella tra le 8 posizioni di spawn del C64, mai sulla
; stessa riga/colonna di P1 o P2.
spawn_monster
sp_tx           JSR random
                ANDA #7
                LDY #spn_x
                LDA A,Y
                STA tmp1
                LDB #SUBSTEPS_X
                MUL
                STB ab_x
                LDA pl_ax
                CMPA #$FF
                BEQ sp_x2
                SUBA ab_x
                BPL sp_x1
                NEGA
sp_x1           CMPA #ALIGN_R
                BLO sp_tx
sp_x2           LDA p2_ax
                CMPA #$FF
                BEQ sp_ty
                SUBA ab_x
                BPL sp_x3
                NEGA
sp_x3           CMPA #ALIGN_R
                BLO sp_tx
sp_ty           JSR random
                ANDA #7
                LDY #spn_y
                LDA A,Y
                STA tmp2
                LDB #SUBSTEPS_Y
                MUL
                STB ab_y
                LDA pl_ax
                CMPA #$FF
                BEQ sp_y2
                LDA pl_ay
                SUBA ab_y
                BPL sp_y1
                NEGA
sp_y1           CMPA #ALIGN_R
                BLO sp_ty
sp_y2           LDA p2_ax
                CMPA #$FF
                BEQ sp_ok
                LDA p2_ay
                SUBA ab_y
                BPL sp_y3
                NEGA
sp_y3           CMPA #ALIGN_R
                BLO sp_ty
sp_ok           LDA tmp1
                STA actor_x,X
                LDA tmp2
                STA actor_y,X
                CLR actor_sx,X
                CLR actor_sy,X
                RTS

; rand_want: X = indice -> direzione desiderata casuale (+-1, +-1)
rand_want
                JSR random
                ANDA #2
                DECA                        ; 0 -> $FF, 2 -> 1
                STA actor_wx,X
                JSR random
                ANDA #4
                LSRA
                DECA
                STA actor_wy,X
                RTS

; check_events: eventi differiti (a fine frame, mai a meta' aggiornamento)
check_events
                LDA pending
                BEQ ce_end
                CLR pending
                CMPA #PEND_NEXT
                BEQ ce_next
                CMPA #PEND_WORLUK
                BEQ ce_wl
                CMPA #PEND_WIZARD
                BEQ ce_wz
                LDB #40                     ; game over: lascia finire l'esplosione
ce_go           PSHS B
                JSR wait_frame
                PULS B
                DECB
                BNE ce_go
                JSR clear_maze_area
                LDX #tx_gameover            ; "GAME OVER"
                JSR draw_text
                LDX #snd_pattern_3          ; jingle C64 Game Over (parte 1)
                JSR jg_play
                LDX #snd_pattern_1          ; jingle C64 Game Over (parte 2, come su C64)
                JSR jg_play
                JSR hs_insert               ; classifica (P1 e P2) + schermata iniziale
                JSR title_screen
                JSR new_game
                JMP start_dungeon
ce_next         LDB #110                    ; lascia terminare l'effetto sonoro (Worluk/Wizard)
ce_wait_sfx     LDA snd_left
                BEQ ce_do_next
                LDA phase                   ; se Worluk o Wizard: lampeggia lo sfondo come flashing_background_colors sul C64
                BEQ ce_nf
                TFR B,A
                ANDA #$06
                LDX #bg_flash_pal
                LDD A,X
                CLR PAL_IDX
                STA PAL_DATA
                STB PAL_DATA
ce_nf           PSHS B
                JSR wait_frame
                PULS B
                DECB
                BNE ce_wait_sfx
ce_do_next      CLR PAL_IDX
                CLR PAL_DATA
                CLR PAL_DATA
                JMP start_dungeon

bg_flash_pal    FCB $0F,$00,$00,$00,$00,$0C,$00,$00
ce_wl           JSR enter_worluk
                RTS
ce_wz           JSR enter_wizard
ce_end          RTS

; clear_monsters: elimina tutti i mostri e le loro pallottole
clear_monsters
                LDX #2
cl_lp           LDA #DEAD
                STA actor_type,X
                CLR actor_dying,X
                CLR firing,X
                LEAX 1,X
                CMPX #MAX_ACTORS
                BNE cl_lp
                RTS

; enter_worluk: dungeon > 0: resta solo Worluk, che fugge verso la porta opposta
enter_worluk
                LDA current_dungeon
                BNE ew_go
                JMP start_dungeon           ; niente Worluk nel primo dungeon
ew_go           LDA #1
                STA phase
                JSR clear_monsters
                LDX #2
                LDA #WORLUK
                STA actor_type,X
                JSR init_monster
                CLR actor_spd,X             ; veloce
                CLR actor_inv,X
                LDA actor_x,X
                CMPA #5
                BLO ew_r
                CLRA                        ; nato a destra: fugge a sinistra
                BRA ew_t
ew_r            LDA #MAZE_W-1
ew_t            STA tgt_x
                LDA #2
                STA tgt_y
                CLR warp_open
                LDA #WORLUK_WAIT
                STA warp_timer
                RTS

enter_wizard
                LDA #2
                STA phase
                JSR clear_monsters
                LDX #2
                LDA #WIZARD
                STA actor_type,X
                JSR init_monster
                CLR actor_spd,X
                LDA #1
                STA warp_open
                RTS


;-------------------------------------------------------------------------------
; Input: Joystick 0/1 ($A7CC/$A7CD) + Tastiera MO6/PC128 ($A7C1) per P1 e P2
;   P1: Joystick 0 oppure Frecce ($62,$42,$52,$32) + Spazio ($40) / Invio ($68) / '1' ($5E)
;   P2: Joystick 1 oppure W/Z ($4A,$60), S ($46), A/Q ($56,$5A), D ($36) + Ctrl ($6A) / X ($50) / '2' ($4E)
;-------------------------------------------------------------------------------
read_joystick
                CLR joy_up
                CLR joy_down
                CLR joy_left
                CLR joy_right
                CLR joy_fire
                CLR joy2_up
                CLR joy2_down
                CLR joy2_left
                CLR joy2_right
                CLR joy2_fire
				PSHS CC
				ORCC #$50
                LDA JOY_PRA
                COMA
                STA joy_raw
                BITA #JOY_B_UP
                BEQ rj_d
                INC joy_up
rj_d            BITA #JOY_B_DOWN
                BEQ rj_l
                INC joy_down
rj_l            BITA #JOY_B_LEFT
                BEQ rj_r
                INC joy_left
rj_r            BITA #JOY_B_RIGHT
                BEQ rj_2u
                INC joy_right
rj_2u           BITA #JOY2_B_UP
                BEQ rj_2d
                INC joy2_up
rj_2d           BITA #JOY2_B_DOWN
                BEQ rj_2l
                INC joy2_down
rj_2l           BITA #JOY2_B_LEFT
                BEQ rj_2r
                INC joy2_left
rj_2r           BITA #JOY2_B_RIGHT
                BEQ rj_f
                INC joy2_right
rj_f			LDA JOY_PRB
                COMA
                BITA #JOY_B_FIRE
                BEQ rj_2f
                INC joy_fire
rj_2f           BITA #JOY2_B_FIRE
                BEQ rj_kb1
                INC joy2_fire
                ; --- Tastiera P1 ---
rj_kb1          LDA #$62                    ; Freccia SU
                LBSR chk_key
                BEQ rj_kd1
                INC joy_up
rj_kd1          LDA #$42                    ; Freccia GIU
                BSR chk_key
                BEQ rj_kl1
                INC joy_down
rj_kl1          LDA #$52                    ; Freccia SX
                BSR chk_key
                BEQ rj_kr1
                INC joy_left
rj_kr1          LDA #$32                    ; Freccia DX
                BSR chk_key
                BEQ rj_kf1
                INC joy_right
rj_kf1          LDA #$40                    ; Spazio
                BSR chk_key
                BNE rj_kf1_ok
                LDA #$68                    ; Invio (Enter)
                BSR chk_key
                BNE rj_kf1_ok
                LDA #$5E                    ; Tasto '1'
                BSR chk_key
                BEQ rj_kb2
rj_kf1_ok       INC joy_fire
                ; --- Tastiera P2 ---
rj_kb2          LDA #$4A                    ; W (PC128) / Z (MO6)
                BSR chk_key
                BNE rj_ku2_ok
                LDA #$60                    ; W (MO6)
                BSR chk_key
                BEQ rj_kd2
rj_ku2_ok       INC joy2_up
rj_kd2          LDA #$46                    ; S
                BSR chk_key
                BEQ rj_kl2
                INC joy2_down
rj_kl2          LDA #$56                    ; A (PC128) / Q (MO6)
                BSR chk_key
                BNE rj_kl2_ok
                LDA #$5A                    ; A (MO6)
                BSR chk_key
                BEQ rj_kr2
rj_kl2_ok       INC joy2_left
rj_kr2          LDA #$36                    ; D
                BSR chk_key
                BEQ rj_kf2
                INC joy2_right
rj_kf2          LDA #$6A                    ; Control (CNT)
                BSR chk_key
                BNE rj_kf2_ok
                LDA #$50                    ; X
                BSR chk_key
                BNE rj_kf2_ok
                LDA #$4E                    ; Tasto '2'
                BSR chk_key
                BEQ rj_kb_end
rj_kf2_ok       INC joy2_fire
rj_kb_end       CLR SYS_PIA_B               ; riporta buzzer/matrice a riposo
				PULS CC
                RTS

; chk_key: A = selettore matrice $A7C1 -> Z=0 (BNE) se il tasto e' premuto (bit 7 = 0)
chk_key         
				STA SYS_PIA_B
                LDA SYS_PIA_B
                COMA
                ANDA #$80
                RTS

; handle_input: direzione richiesta per P1 (indice 0) e P2 (indice 1)
; Legge sia l'asse X che l'asse Y indipendentemente (per consentire la svolta fluida agli incroci come sul C64)
handle_input
                CLR want_x
                CLR want_y
                LDA actor_type
                CMPA #PLAYER1
                BNE hi_p2
                LDA actor_dying
                BNE hi_p2                   ; P1 sta morendo: nessun comando
                LDA joy_left
                BEQ hi_r
                LDA #DIR_LEFT
                STA want_x
                BRA hi_u
hi_r            LDA joy_right
                BEQ hi_u
                LDA #DIR_RIGHT
                STA want_x
hi_u            LDA joy_up
                BEQ hi_d
                LDA #DIR_UP
                STA want_y
                BRA hi_fire
hi_d            LDA joy_down
                BEQ hi_fire
                LDA #DIR_DOWN
                STA want_y
hi_fire         LDA joy_fire
                BEQ hi_p2
                LDX #0
                JSR try_fire
hi_p2           CLR want_x+1
                CLR want_y+1
                LDA actor_type+1
                CMPA #PLAYER2
                BNE hi_end
                LDA actor_dying+1
                BNE hi_end                  ; P2 sta morendo: nessun comando
                LDA joy2_left
                BEQ hi2_r
                LDA #DIR_LEFT
                STA want_x+1
                BRA hi2_u
hi2_r           LDA joy2_right
                BEQ hi2_u
                LDA #DIR_RIGHT
                STA want_x+1
hi2_u           LDA joy2_up
                BEQ hi2_d
                LDA #DIR_UP
                STA want_y+1
                BRA hi2_fire
hi2_d           LDA joy2_down
                BEQ hi2_fire
                LDA #DIR_DOWN
                STA want_y+1
hi2_fire        LDA joy2_fire
                BEQ hi_end
                LDX #1
                JSR try_fire
hi_end          RTS

; try_fire: X = indice attore; spara nella direzione di mira (se non ha gia' una
; pallottola attiva). La pallottola parte dalla posizione dell'attore; l'asse
; perpendicolare alla traiettoria si allinea alla cella piu' vicina.
try_fire
                LDA firing,X
                BMI tf_end
                LDA #$80
                STA firing,X
                CMPX #2
                BHS tf_ms
                LDA #1                      ; SFX_PLAYER_SHOOTS
                BRA tf_snd
tf_ms           CLRA                        ; SFX_MONSTER_SHOOTS
tf_snd          JSR snd_play
                LDA actor_x,X
                STA bullet_x,X
                LDA actor_y,X
                STA bullet_y,X
                LDA actor_sx,X
                STA bullet_sx,X
                LDA actor_sy,X
                STA bullet_sy,X
                LDA actor_fx,X
                STA bullet_dx,X
                LDA actor_fy,X
                STA bullet_dy,X
                LDA bullet_dx,X
                BEQ tf_vert
                LDA bullet_sy,X             ; traiettoria orizzontale: allinea la riga
                CMPA #SUBSTEPS_Y/2
                BLO tf_sy0
                INC bullet_y,X
tf_sy0          CLR bullet_sy,X
                RTS
tf_vert         LDA bullet_sx,X             ; traiettoria verticale: allinea la colonna
                CMPA #(SUBSTEPS_X+1)/2
                BLO tf_sx0
                INC bullet_x,X
tf_sx0          CLR bullet_sx,X
tf_end          RTS

;===============================================================================
; MOVIMENTO
;===============================================================================
; cell_mask: tmp_x,tmp_y = cella -> A = maschera muri. Clobbera B,U; preserva X.
cell_mask
                LDA tmp_y
                LDB #MAZE_W
                MUL
                ADDB tmp_x
                ADCA #0
                TFR D,U
                LDA maze,U
                RTS

; step_move: avanza di UN sotto-passo la posizione m_cx/m_cy/m_sx/m_sy nella
; direzione m_hx/m_hy (un solo asse; m_hx ha la precedenza). Preserva X.
;   m_blk = 0 mosso | 1 bloccato da un muro | 2 attraversata porta warp (teleport)
;           | 3 fermo: non allineato sull'altro asse
; Il muro si controlla solo sul confine di cella (sotto-passo 0).
step_move
                CLR m_blk
                LDA m_hx
                LBEQ sm_v
                LDA m_sy                    ; ---- orizzontale ----
                LBNE sm_misal                ; non allineato in Y
                LDA m_sx
                BNE sm_hfree                ; a meta' cella: niente controllo muro
                LDA m_cx
                STA tmp_x
                LDA m_cy
                STA tmp_y
                JSR cell_mask
                LDB m_hx
                BMI sm_hl_chk
                BITA #WALL_E                ; verso destra, sul confine
                LBNE sm_wall
                LDA m_cx
                CMPA #MAZE_W-1
                BNE sm_hfree
                LDA warp_open
                LBEQ sm_wall                ; porta chiusa: e' un muro
                CLR m_cx                    ; porta warp: da destra a sinistra
                LDA #2
                STA m_blk
                RTS
sm_hl_chk       BITA #WALL_W                ; verso sinistra, sul confine
                LBNE sm_wall
sm_hfree        LDB m_hx
                BMI sm_hl
                INC m_sx                    ; destra: un sotto-passo
                LDA m_sx
                CMPA #SUBSTEPS_X
                LBNE sm_done
                CLR m_sx
                INC m_cx
                RTS
sm_hl           LDA m_sx                    ; sinistra
                BEQ sm_hl0
                DEC m_sx
                RTS
sm_hl0          LDA m_cx                    ; dal confine verso la cella a sinistra
                BNE sm_hl1
                LDA warp_open
                LBEQ sm_wall
                LDA #MAZE_W-1               ; porta warp: da sinistra a destra
                STA m_cx
                LDA #2
                STA m_blk
                RTS
sm_hl1          DEC m_cx
                LDA #SUBSTEPS_X-1
                STA m_sx
                RTS
sm_v            LDA m_hy                    ; ---- verticale ----
                BEQ sm_done
                LDA m_sx
                BNE sm_misal                ; non allineato in X
                LDA m_sy
                BNE sm_vfree
                LDA m_cx
                STA tmp_x
                LDA m_cy
                STA tmp_y
                JSR cell_mask
                LDB m_hy
                BMI sm_vu_chk
                BITA #WALL_S                ; verso il basso, sul confine
                BNE sm_wall
                BRA sm_vfree
sm_vu_chk       BITA #WALL_N                ; verso l'alto, sul confine
                BNE sm_wall
sm_vfree        LDB m_hy
                BMI sm_vu
                INC m_sy                    ; giu': un sotto-passo
                LDA m_sy
                CMPA #SUBSTEPS_Y
                BNE sm_done
                CLR m_sy
                INC m_cy
                RTS
sm_vu           LDA m_sy                    ; su
                BEQ sm_vu0
                DEC m_sy
                RTS
sm_vu0          DEC m_cy                    ; dal confine verso la cella sopra
                LDA #SUBSTEPS_Y-1
                STA m_sy
                RTS
sm_misal        LDA #3
                STA m_blk
                RTS
sm_wall         LDA #1
                STA m_blk
sm_done         RTS

; load_actor / store_actor: X = indice attore <-> variabili m_*
load_actor
                LDA actor_x,X
                STA m_cx
                LDA actor_y,X
                STA m_cy
                LDA actor_sx,X
                STA m_sx
                LDA actor_sy,X
                STA m_sy
                LDA actor_hx,X
                STA m_hx
                LDA actor_hy,X
                STA m_hy
                RTS

store_actor
                LDA m_cx
                STA actor_x,X
                LDA m_cy
                STA actor_y,X
                LDA m_sx
                STA actor_sx,X
                LDA m_sy
                STA actor_sy,X
                LDA m_hx
                STA actor_hx,X
                LDA m_hy
                STA actor_hy,X
                RTS

update_actors
                LDA #$FF
                STA pl_ax
                STA p2_ax
                LDA actor_type
                CMPA #PLAYER1
                BNE ua_i1
                LDA actor_dying
                BNE ua_i1
                LDX #0
                JSR calc_abs                ; posizione assoluta di P1 (sotto-passi)
                LDA ab_x
                STA pl_ax
                LDA ab_y
                STA pl_ay
ua_i1           LDA p_invul
                BEQ ua_p2
                DEC p_invul
ua_p2           LDA actor_type+1
                CMPA #PLAYER2
                BNE ua_i2
                LDA actor_dying+1
                BNE ua_i2
                LDX #1
                JSR calc_abs                ; posizione assoluta di P2 (sotto-passi)
                LDA ab_x
                STA p2_ax
                LDA ab_y
                STA p2_ay
ua_i2           LDA p_invul+1
                BEQ ua_ni
                DEC p_invul+1
ua_ni           LDA warp_open
                BNE ua_w
                DEC warp_timer
                BNE ua_w
                LDA #1
                STA warp_open               ; la porta si riapre
                JSR mus_faster              ; ... e la musica accelera
ua_w            CLR actual_actor
ua_lp           LDX #0
                LDB actual_actor
                ABX
                LDA actor_type,X
                CMPA #DEAD
                BEQ ua_nx
                LDA actor_dying,X
                BEQ ua_alive
                JSR process_dying
                BRA ua_nx
ua_alive        LDA actor_type,X
                CMPA #PLAYER1
                BEQ ua_pl
                CMPA #PLAYER2
                BEQ ua_pl                   ; P2 attivo!
                JSR inv_timers
                JSR move_monster
                BRA ua_nx
ua_pl           JSR move_player
ua_nx           INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                BNE ua_lp
                RTS

; calc_abs: X = attore -> ab_x, ab_y = posizione assoluta in sotto-passi. Preserva X.
calc_abs
                LDA actor_x,X
                LDB #SUBSTEPS_X
                MUL
                ADDB actor_sx,X
                STB ab_x
                LDA actor_y,X
                LDB #SUBSTEPS_Y
                MUL
                ADDB actor_sy,X
                STB ab_y
                RTS

close_warp
                LDA #4                      ; SFX_WARP_DOOR_CLOSED
                JSR snd_play
                CLR warp_open
                LDA #WARP_FRAMES
                STA warp_timer
                RTS

; move_player: X = indice (0=P1, 1=P2). Si muove solo mentre il comando e' premuto.
; Fedele al C64:
;   - Su un tratto orizzontale (m_sx != 0): se si preme SU/GIU senza SX/DX, prosegue nella
;     direzione orizzontale attuale (actor_fx) fino all'incrocio senza MAI girarsi indietro!
;   - Su un tratto verticale (m_sy != 0): se si preme SX/DX senza SU/GIU, prosegue nella
;     direzione verticale attuale (actor_fy) fino all'incrocio senza MAI girarsi indietro!
;   - Allineato all'incrocio (m_sx=0, m_sy=0): se si preme una diagonale, prova prima a svoltare
;     sull'asse perpendicolare (se aperto); se si preme un solo asse bloccato da un muro,
;     aggiorna comunque actor_fx/actor_fy per permettere di girarsi sul posto e mirare!
move_player
                LDA want_x,X
                ORA want_y,X
                LBEQ mp_end                 ; a riposo: fermo
                JSR load_actor
                CLR m_hx
                CLR m_hy
                LDA m_sx
                ORA m_sy
                BEQ mp_aligned              ; allineato a inizio cella (m_sx=0, m_sy=0)
                LDA m_sy
                BNE mp_vseg
                ; --- Tratto orizzontale (m_sx != 0, m_sy == 0) ---
                LDA want_x,X
                BNE mp_sethx                ; richiesta orizzontale esplicita (avanti o inversione)
                LDA actor_fx,X              ; richiesta solo verticale: continua nella direzione attuale!
                BNE mp_sethx
                LDA #DIR_LEFT
mp_sethx        STA m_hx
                BRA mp_move
                ; --- Tratto verticale (m_sy != 0, m_sx == 0) ---
mp_vseg         LDA want_y,X
                BNE mp_sethy                ; richiesta verticale esplicita (avanti o inversione)
                LDA actor_fy,X              ; richiesta solo orizzontale: continua nella direzione attuale!
                BNE mp_sethy
                LDA #DIR_UP
mp_sethy        STA m_hy
                BRA mp_move
                ; --- Allineato all'incrocio (m_sx == 0, m_sy == 0) ---
mp_aligned      LDA want_x,X
                BEQ mp_take_y
                LDA want_y,X
                BEQ mp_take_x
                ; Diagonale premuta all'incrocio: privilegia la svolta perpendicolare se aperta
                LDA actor_fx,X
                BNE mp_try_v
                ; Stava andando in verticale: prova prima a svoltare in orizzontale (want_x)
                LDA want_x,X
                STA m_hx
                JSR step_move
                LDA m_blk
                BEQ mp_moved
                CMPA #2
                BEQ mp_moved
                CLR m_hx
                LDA want_y,X
                STA m_hy
                BRA mp_move
mp_try_v        ; Stava andando in orizzontale: prova prima a svoltare in verticale (want_y)
                LDA want_y,X
                STA m_hy
                JSR step_move
                LDA m_blk
                BEQ mp_moved
                CLR m_hy
                LDA want_x,X
                STA m_hx
                BRA mp_move
mp_take_x       LDA want_x,X
                STA m_hx
                BRA mp_move
mp_take_y       LDA want_y,X
                STA m_hy
mp_move         JSR step_move
mp_moved        JSR store_actor
                LDA m_blk
                BEQ mp_face                 ; mosso: lo sprite guarda dove va davvero
                CMPA #2
                BEQ mp_face                 ; porta warp attraversata
                ; Se e' allineato (m_sx=0, m_sy=0) e bloccato da un muro con un solo tasto premuto,
                ; aggiorna comunque la direzione di mira (actor_fx/fy) cosi' puo' girarsi e sparare!
                LDA m_sx
                ORA m_sy
                BNE mp_nf
                LDA want_x,X
                BEQ mp_f_vy
                LDA want_y,X
                BNE mp_nf
                BRA mp_face
mp_f_vy         LDA want_y,X
                BEQ mp_nf
mp_face         LDA m_hx
                STA actor_fx,X
                LDA m_hy
                STA actor_fy,X
mp_nf           LDA m_blk
                CMPA #2
                BNE mp_nw
                JSR close_warp
mp_nw           LDA m_blk
                ANDA #1                     ; 0 mosso, 2 warp: animazione; 1/3: fermo
                BNE mp_end
                JSR anim_step
mp_end          RTS

; anim_step: X = attore -> actor_anim 0..5 (fotogramma = anim/2)
anim_step
                LDA actor_anim,X
                INCA
                CMPA #6
                BNE as_ok
                CLRA
as_ok           STA actor_anim,X
                RTS

;-------------------------------------------------------------------------------
; MOSTRI
;-------------------------------------------------------------------------------
; inv_timers: X = mostro. Ogni 'secondo' conta; scaduto: accelera e (Garwor/Thorwor)
; diventa invisibile; poi si ripete ogni 10 secondi.
inv_timers
                LDA actor_sec,X
                SUBA #3                     ; un passo di simulazione = ~3 tick IRQ (50/SIM_HZ)
                STA actor_sec,X
                BPL it_end
                LDA #SEC_TICKS
                STA actor_sec,X
                DEC actor_invt,X
                BPL it_end
                LDA #10
                STA actor_invt,X
                DEC actor_spd,X             ; piu' veloce (puo' scendere a $FF)
                LDA actor_type,X
                CMPA #GARWOR
                BEQ it_inv
                CMPA #THORWOR
                BNE it_end
it_inv          LDA #1
                STA actor_inv,X
it_end          RTS

; process_dying: X = attore in esplosione; a fine esplosione applica la conseguenza.
process_dying
                DEC actor_dying,X
                BNE pdy_end
                CMPX #2
                BHS pdy_mon
                JMP player_died
pdy_mon         JMP monster_died
pdy_end         RTS

; player_died: X = 0 (P1) oppure 1 (P2)
player_died
                CMPX #0
                BNE pdy_p2
                LDA lives
                BEQ pdy_1dead               ; P1 senza vite extra
                DEC lives
                LDA #10
                STA actor_x
                LDA #DIR_LEFT
                STA actor_fx
                BRA pdy_resp
pdy_1dead       LDA #$FF
                STA lives
                STA pl_ax
                LDA #DEAD
                STA actor_type
                BRA pdy_chk
pdy_p2          LDA lives2
                BEQ pdy_2dead               ; P2 senza vite extra
                DEC lives2
                CLR actor_x+1
                LDA #DIR_RIGHT
                STA actor_fx+1
                BRA pdy_resp
pdy_2dead       LDA #$FF
                STA lives2
                STA p2_ax
                LDA #DEAD
                STA actor_type+1
                BRA pdy_chk
pdy_resp        LDA #7                      ; SFX_PLAYER_LAUNCH
                JSR snd_play
                LDA #5
                STA actor_y,X
                CLR actor_sx,X
                CLR actor_sy,X
                CLR actor_hx,X
                CLR actor_hy,X
                CLR actor_anim,X
                CLR firing,X
                CLR actor_fy,X
                LDA #INVUL_FRAMES
                STA p_invul,X
pdy_chk         JSR draw_lives
                LDA lives
                ANDA lives2
                CMPA #$FF                   ; entrambi $FF -> Game Over
                BEQ pdy_over
                LDA phase
                CMPA #2
                BNE pdy_done
                LDA #10                     ; SFX_WIZARD_ESCAPED
                JSR snd_play
                LDA #PEND_NEXT              ; il Wizard e' fuggito: nuovo dungeon
                STA pending
pdy_done        RTS
pdy_over        LDA #PEND_OVER
                STA pending
                RTS

; monster_died: X = mostro appena esploso (sostituzioni come monster_is_dead del C64)
monster_died
                LDA actor_type,X
                CMPA #WORLUK
                BEQ md_wl
                CMPA #WIZARD
                BEQ md_wz
                CMPA #BURWOR
                BNE md_nb
                DEC burwors_alive
                LDA current_dungeon
                CMPA burwors_alive
                BLO md_none                 ; dungeon < Burwor rimasti: nessun rimpiazzo
                LDA actor_type,X
md_nb           CMPA #THORWOR
                BEQ md_none                 ; i Thorwor non si rimpiazzano
                INCA                        ; Burwor -> Garwor -> Thorwor
                STA actor_type,X
                JSR init_monster
                RTS
md_none         LDA #DEAD
                STA actor_type,X
                DEC normal_left
                BPL md_end
                LDA #PEND_WORLUK            ; finiti: arriva Worluk
                STA pending
md_end          RTS
md_wl           LDA #DEAD
                STA actor_type,X
                LDA #8                      ; SFX_WORLUK_KILLED
                JSR snd_play
                LDA #1
                STA dbl_next                ; dungeon successivo a punteggio doppio
                JSR random
                ANDA #3
                BNE md_nx
                LDA #PEND_WIZARD            ; 1 su 4
                BRA md_set
md_nx           LDA #PEND_NEXT
md_set          STA pending
                RTS
md_wz           LDA #DEAD
                STA actor_type,X
                LDA #11                     ; SFX_WIZARD_KILLED
                JSR snd_play
                LDA #1
                STA dbl_next
                LDA #PEND_NEXT
                STA pending
                RTS

; move_monster: X = indice. Un'"azione" ogni (s+1)/4 frame saltati.
move_monster
                LDA actor_timer,X
                BEQ mm_go
                DEC actor_timer,X
                RTS
mm_go           LDA actor_spd,X
                BPL mm_sp
                CLR actor_inv,X             ; velocita' esaurita: torna visibile
                CLR actor_spd,X
                CLRA
mm_sp           INCA
                LSRA
                LSRA
                STA actor_timer,X
                JSR load_actor
                JSR mon_shoot
                DEC once_timer
                BNE mm_nc
                LDA #ONCE_RELOAD
                STA once_timer
                JSR chase_want              ; "una volta ogni tanto" verso il giocatore
mm_nc           JSR random
                BNE mm_ar
                JSR rand_want               ; 1 volta su 256: direzione casuale
mm_ar           LDA m_sx
                ORA m_sy
                BNE mm_step                 ; non allineato: prosegue
                LDA actor_type,X
                CMPA #WORLUK
                BNE mm_dec
                JSR random
                ANDA #3
                BNE mm_dec
                JSR target_want             ; Worluk: ogni tanto verso la porta
mm_dec          JSR mon_decide
mm_step         LDA actor_type,X
                CMPA #WORLUK
                BNE mm_ns
                LDA m_sx
                ORA m_sy
                BNE mm_ns                   ; suona solo ad inizio cella per non rallentare Worluk
                LDA snd_left                ; suona solo se nessun effetto e' in corso
                BNE mm_ns
                LDA #3                      ; SFX_WORLUK_MOVING (solo se libero)
                JSR snd_play
mm_ns           JSR step_move
                JSR store_actor
                LDA m_blk
                CMPA #2
                BEQ mm_warp
                ANDA #1
                BNE mm_stop
                LDA m_hx
                ORA m_hy
                BEQ mm_vis
                LDA m_hx
                STA actor_fx,X
                LDA m_hy
                STA actor_fy,X
                JSR anim_step
                BRA mm_vis
mm_stop         CLR actor_hx,X
                CLR actor_hy,X
                JSR rand_want
                BRA mm_vis
mm_warp         JSR close_warp
                LDA actor_type,X
                CMPA #WORLUK
                BNE mm_vis
                LDA #9                      ; SFX_WORLUK_ESCAPED
                JSR snd_play
                JSR random                  ; Worluk e' fuggito
                ANDA #7
                BNE mm_esc
                LDA #PEND_WIZARD            ; 1 su 8
                BRA mm_esc2
mm_esc          LDA #PEND_NEXT
mm_esc2         STA pending
                RTS
; visibilita': allineato con P1 o P2 -> visibile; Burwor e altri sempre visibili
mm_vis          JSR calc_abs
                LDA pl_ax
                CMPA #$FF
                BEQ mv_p2
                LDA ab_x
                SUBA pl_ax
                BPL mv1
                NEGA
mv1             CMPA #ALIGN_R
                BLO mm_show
                LDA ab_y
                SUBA pl_ay
                BPL mv2
                NEGA
mv2             CMPA #ALIGN_R
                BLO mm_show
mv_p2           LDA p2_ax
                CMPA #$FF
                BEQ mv_chk
                LDA ab_x
                SUBA p2_ax
                BPL mv3
                NEGA
mv3             CMPA #ALIGN_R
                BLO mm_show
                LDA ab_y
                SUBA p2_ay
                BPL mv4
                NEGA
mv4             CMPA #ALIGN_R
                BLO mm_show
mv_chk          LDA actor_type,X
                CMPA #GARWOR
                BEQ mm_end
                CMPA #THORWOR
                BEQ mm_end
mm_show         LDA actor_inv,X
                BEQ mm_sh0
                LDA #5                      ; SFX_INVISIBILITY_ENDS
                JSR snd_play
mm_sh0          CLR actor_inv,X
mm_end          RTS

; mon_shoot: 50% di tentare; i mostri dispari puntano P1, i mostri pari puntano P2
; (come sul C64), solo se allineati in x o in y. Il Wizard spara a caso 1/32.
mon_shoot
                LDA actor_type,X
                CMPA #WIZARD
                BEQ msh_wiz
                JSR random
                BPL msh_no
                TFR X,D
                ANDB #1
                BEQ msh_p2                  ; indice pari: punta al P2
                LDA pl_ax
                CMPA #$FF
                BEQ msh_p2                  ; se P1 e' morto, ripiega su P2
                JSR calc_abs
                LDA ab_x
                CMPA pl_ax
                BEQ msh_fire
                LDA ab_y
                CMPA pl_ay
                BEQ msh_fire
                RTS
msh_p2          LDA p2_ax
                CMPA #$FF
                BEQ msh_no                  ; P2 non in gioco: i mostri pari non sparano
                JSR calc_abs
                LDA ab_x
                CMPA p2_ax
                BEQ msh_fire
                LDA ab_y
                CMPA p2_ay
                BNE msh_no
msh_fire        JSR try_fire
msh_no          RTS
msh_wiz         JSR random
                ANDA #$1F
                BNE msh_no
                BRA msh_fire

; chase_want: direzione desiderata verso P1 (mostri dispari) o P2 (mostri pari)
chase_want
                JSR calc_abs
                TFR X,D
                ANDB #1
                BEQ cw_try2
cw_try1         LDA pl_ax
                CMPA #$FF
                BNE cw_use1
                LDA p2_ax
                CMPA #$FF
                BNE cw_use2
                RTS
cw_try2         LDA p2_ax
                CMPA #$FF
                BNE cw_use2
                BRA cw_try1
cw_use1         LDB pl_ax
                STB tmp1
                LDB pl_ay
                STB tmp2
                BRA cw_go
cw_use2         LDB p2_ax
                STB tmp1
                LDB p2_ay
                STB tmp2
cw_go           LDA ab_x
                CMPA tmp1
                BLO cw_r
                LDA #DIR_LEFT
                BRA cw_x
cw_r            LDA #DIR_RIGHT
cw_x            STA actor_wx,X
                LDA ab_y
                CMPA tmp2
                BLO cw_d
                LDA #DIR_UP
                BRA cw_y
cw_d            LDA #DIR_DOWN
cw_y            STA actor_wy,X
                RTS

; target_want: direzione desiderata verso la cella (tgt_x,tgt_y); sul bersaglio spinge
; fuori dalla porta
target_want
                LDA tgt_x
                CMPA m_cx
                BEQ tw_x0
                BHI tw_xp
                LDA #DIR_LEFT
                BRA tw_xs
tw_xp           LDA #DIR_RIGHT
                BRA tw_xs
tw_x0           LDA tgt_y
                CMPA m_cy
                BNE tw_xz
                LDA tgt_x                   ; sul bersaglio: verso l'esterno
                BEQ tw_xl
                LDA #DIR_RIGHT
                BRA tw_xs
tw_xl           LDA #DIR_LEFT
                BRA tw_xs
tw_xz           CLRA
tw_xs           STA actor_wx,X
                LDA tgt_y
                CMPA m_cy
                BEQ tw_y0
                BHI tw_yp
                LDA #DIR_UP
                BRA tw_ys
tw_yp           LDA #DIR_DOWN
                BRA tw_ys
tw_y0           CLRA
tw_ys           STA actor_wy,X
                RTS

; mon_decide: a una cella (allineato) sceglie la direzione tra quelle desiderate libere:
; entrambe libere -> asse a caso; nessuna -> fermo e nuova direzione casuale.
mon_decide
                LDA m_cx
                STA tmp_x
                LDA m_cy
                STA tmp_y
                JSR cell_mask
                STA dc_mask
                CLR dc_h
                CLR dc_v
                LDA actor_wx,X
                BEQ dc_hn
                BMI dc_hl
                LDA dc_mask
                ANDA #WALL_E
                BNE dc_hn
                LDA #DIR_RIGHT
                STA dc_h
                BRA dc_hn
dc_hl           LDA dc_mask
                ANDA #WALL_W
                BNE dc_hn
                LDA #DIR_LEFT
                STA dc_h
dc_hn           LDA actor_wy,X
                BEQ dc_vn
                BMI dc_vu
                LDA dc_mask
                ANDA #WALL_S
                BNE dc_vn
                LDA #DIR_DOWN
                STA dc_v
                BRA dc_vn
dc_vu           LDA dc_mask
                ANDA #WALL_N
                BNE dc_vn
                LDA #DIR_UP
                STA dc_v
dc_vn           LDA dc_h
                BEQ dc_tv
                LDA dc_v
                BEQ dc_uh
                JSR random
                ANDA #1
                BNE dc_uv
dc_uh           LDA dc_h
                STA m_hx
                CLR m_hy
                RTS
dc_tv           LDA dc_v
                BEQ dc_stuck
dc_uv           LDA dc_v
                STA m_hy
                CLR m_hx
                RTS
dc_stuck        CLR m_hx
                CLR m_hy
                JSR rand_want
                RTS

random          ; LFSR 8 bit a scorrimento destro, maschera $B8 (periodo 255)
                LDA rnd
                LSRA
                BCC rnd_ok
                EORA #$B8
rnd_ok          STA rnd
                RTS

;===============================================================================
; PROIETTILI
;===============================================================================
; Ogni frame la pallottola avanza di BULLET_STEPS sotto-passi; si ferma contro un
; muro o uscendo da una porta warp.
update_bullets
                CLR actual_actor
ub_lp           LDX #0
                LDB actual_actor
                ABX
                LDA firing,X
                BPL ub_nx
                LDA bullet_x,X
                STA m_cx
                LDA bullet_y,X
                STA m_cy
                LDA bullet_sx,X
                STA m_sx
                LDA bullet_sy,X
                STA m_sy
                LDA bullet_dx,X
                STA m_hx
                LDA bullet_dy,X
                STA m_hy
                LDB #BULLET_STEPS
                CMPX #2
                BLO ub_st
                LDB #MON_BULLET_STEPS       ; pallottole dei mostri: piu' lente
                LDA actor_type,X
                CMPA #WIZARD
                BNE ub_st
                LDB #BULLET_STEPS           ; ... tranne quelle del Wizard
ub_st           PSHS B
                JSR step_move
                PULS B
                LDA m_blk
                BNE ub_stop
                DECB
                BNE ub_st
                LDA m_cx
                STA bullet_x,X
                LDA m_cy
                STA bullet_y,X
                LDA m_sx
                STA bullet_sx,X
                LDA m_sy
                STA bullet_sy,X
                BRA ub_nx
ub_stop         CLR firing,X
ub_nx           INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                LBNE ub_lp
                RTS

; check_hits:
;   (1) collisione tra le pallottole di P1 e P2
;   (2) pallottole di P1 e P2 contro i mostri (assegna punti a P1 o P2)
;   (3) pallottole di P1 contro P2 e viceversa (PvP 1000 punti, come su C64)
;   (4) testa e pallottole dei mostri contro P1 e P2
check_hits
                LDA firing
                BPL ch_loop_st
                LDA firing+1
                BPL ch_loop_st
                LDA bullet_x
                LDB #SUBSTEPS_X
                MUL
                ADDB bullet_sx
                STB tmp1
                LDA bullet_x+1
                LDB #SUBSTEPS_X
                MUL
                ADDB bullet_sx+1
                SUBB tmp1
                BPL ch_bb1
                NEGB
ch_bb1          CMPB #HIT_R
                BHI ch_loop_st
                LDA bullet_y
                LDB #SUBSTEPS_Y
                MUL
                ADDB bullet_sy
                STB tmp2
                LDA bullet_y+1
                LDB #SUBSTEPS_Y
                MUL
                ADDB bullet_sy+1
                SUBB tmp2
                BPL ch_bb2
                NEGB
ch_bb2          CMPB #HIT_R
                BHI ch_loop_st
                CLR firing                  ; le due pallottole si annullano
                CLR firing+1
ch_loop_st      CLR actual_actor
ch_lp           LDX #0
                LDB actual_actor
                ABX
                LDA firing,X
                LBPL ch_nx
                LDA bullet_x,X              ; posizione assoluta della pallottola
                LDB #SUBSTEPS_X
                MUL
                ADDB bullet_sx,X
                STB tmp1
                LDA bullet_y,X
                LDB #SUBSTEPS_Y
                MUL
                ADDB bullet_sy,X
                STB tmp2
                LDY #2
cm_lp           LDA actor_type,Y
                CMPA #BURWOR
                BLO cm_n
                CMPA #WIZARD
                BHI cm_n
                LDA actor_dying,Y
                BNE cm_n
                LDA actor_x,Y               ; posizione assoluta del mostro
                LDB #SUBSTEPS_X
                MUL
                ADDB actor_sx,Y
                SUBB tmp1
                BPL cm_dx
                NEGB
cm_dx           CMPB #HIT_R
                BHI cm_n
                LDA actor_y,Y
                LDB #SUBSTEPS_Y
                MUL
                ADDB actor_sy,Y
                SUBB tmp2
                BPL cm_dy
                NEGB
cm_dy           CMPB #HIT_R
                BHI cm_n
                JSR kill_monster            ; colpito! (X = giocatore che ha sparato)
                CLR firing,X
                BRA ch_nx                   ; una pallottola = un solo bersaglio
cm_n            LEAY 1,Y
                CMPY #MAX_ACTORS
                BNE cm_lp
                ; Controllo PvP (Worrior contro Worrior = 1000 punti come su C64)
                LDY #1
                CMPX #0
                BEQ cm_pvp
                LDY #0
cm_pvp          LDA actor_type,Y
                CMPA #DEAD
                BEQ ch_nx
                LDA actor_dying,Y
                BNE ch_nx
                LDA p_invul,Y
                BNE ch_nx
                LDA actor_x,Y
                LDB #SUBSTEPS_X
                MUL
                ADDB actor_sx,Y
                SUBB tmp1
                BPL cm_pdx
                NEGB
cm_pdx          CMPB #HIT_R
                BHI ch_nx
                LDA actor_y,Y
                LDB #SUBSTEPS_Y
                MUL
                ADDB actor_sy,Y
                SUBB tmp2
                BPL cm_pdy
                NEGB
cm_pdy          CMPB #HIT_R
                BHI ch_nx
                CLR firing,X
                LDA #6                      ; SFX_PLAYER_HIT
                JSR snd_play
                LDA #DYING_FRAMES
                STA actor_dying,Y
                CLR firing,Y
                LDD #1000                   ; 1000 punti per aver colpito l'altro Worrior
                JSR add_score
ch_nx           INC actual_actor
                LDA actual_actor
                CMPA #2
                LBNE ch_lp

check_player_hit
                LDY #0
cph_plp         LDA actor_type,Y
                CMPA #DEAD
                LBEQ cph_pnx
                LDA actor_dying,Y
                LBNE cph_pnx
                LDA p_invul,Y
                LBNE cph_pnx
                CMPY #0
                BNE cph_p2c
                LDA pl_ax
                STA tmp1
                LDA pl_ay
                STA tmp2
                BRA cph_mlp
cph_p2c         LDA p2_ax
                STA tmp1
                LDA p2_ay
                STA tmp2
cph_mlp         LDX #2
cp_lp           LDA firing,X                ; pallottola del mostro contro il giocatore Y
                BPL cp_head
                LDA bullet_x,X
                LDB #SUBSTEPS_X
                MUL
                ADDB bullet_sx,X
                SUBB tmp1
                BPL cp_b1
                NEGB
cp_b1           CMPB #HIT_R
                BHI cp_head
                LDA bullet_y,X
                LDB #SUBSTEPS_Y
                MUL
                ADDB bullet_sy,X
                SUBB tmp2
                BPL cp_b2
                NEGB
cp_b2           CMPB #HIT_R
                BHI cp_head
                CLR firing,X
                BRA cp_hit
cp_head         LDA actor_type,X            ; testa del mostro contro il giocatore Y
                CMPA #BURWOR
                BLO cp_nx
                CMPA #WIZARD
                BHI cp_nx
                LDA actor_dying,X
                BNE cp_nx
                JSR calc_abs
                LDA actor_fx,X
                BEQ cp_hy
                BMI cp_hxl
                LDA ab_x
                ADDA #HEAD_SUB
                BRA cp_hxs
cp_hxl          LDA ab_x
                SUBA #HEAD_SUB
cp_hxs          STA ab_x
                BRA cp_hc
cp_hy           LDA actor_fy,X
                BEQ cp_hc
                BMI cp_hyl
                LDA ab_y
                ADDA #HEAD_SUB
                BRA cp_hys
cp_hyl          LDA ab_y
                SUBA #HEAD_SUB
cp_hys          STA ab_y
cp_hc           LDA ab_x
                SUBA tmp1
                BPL cp_h1
                NEGA
cp_h1           CMPA #HIT_R2
                BHI cp_nx
                LDA ab_y
                SUBA tmp2
                BPL cp_h2
                NEGA
cp_h2           CMPA #HIT_R2
                BHI cp_nx
cp_hit          LDA #6                      ; SFX_PLAYER_HIT
                JSR snd_play
                LDA #DYING_FRAMES
                STA actor_dying,Y
                CLR firing,Y
                BRA cph_pnx
cp_nx           LEAX 1,X
                CMPX #MAX_ACTORS
                LBNE cp_lp
cph_pnx         LEAY 1,Y
                CMPY #2
                LBNE cph_plp
cp_end          RTS

; kill_monster: Y = mostro colpito, X = giocatore (0=P1, 1=P2) -> esplosione + punti. Preserva X,Y.
kill_monster
                LDA #2                      ; SFX_MONSTER_HIT
                JSR snd_play
                LDA #DYING_FRAMES
                STA actor_dying,Y
                LDA actor_type,Y
                SUBA #BURWOR
                ASLA
                TFR A,B
                CLRA
                ADDD #score_tbl
                TFR D,U
                LDD ,U

add_score
                PSHS D,X
                CMPX #0
                BNE as_p2
                ADDD score                  ; P1: score big-endian
                STD score
                LDA dbl_active
                BEQ as_hud
                LDD ,S                      ; dungeon a punteggio doppio
                ADDD score
                STD score
                BRA as_hud
as_p2           ADDD score2                 ; P2: score2 big-endian
                STD score2
                LDA dbl_active
                BEQ as_hud
                LDD ,S
                ADDD score2
                STD score2
as_hud          JSR draw_hud_scores
                PULS D,X,PC


;===============================================================================
; DISEGNO
;===============================================================================
; Le pallottole si cancellano e si ridisegnano SUBITO (cosi' restano visibili durante il
; disegno degli sprite, ~40k cicli), poi si ridisegnano sopra gli sprite per tenerle in primo piano.
draw_all
                JSR erase_actors
                JSR erase_bullets
                JSR draw_bullets
                JSR draw_actors
                JSR draw_bullets
                JSR update_radar
                RTS

;-------------------------------------------------------------------------------
; RADAR: 11 x 6 punti (uno per cella del dungeon) in basso a destra. Mostra TUTTI i mostri
; (anche i Garwor/Thorwor invisibili) con il colore del loro tipo, come update_radar del
; C64; e' attivo solo nella fase normale (con Worluk/Wizard resta spento).
; radar_new = mappa calcolata, radar_prev = mappa disegnata: si ridisegnano solo le
; celle cambiate ($FF = da disegnare).
;-------------------------------------------------------------------------------
draw_radar_box
                LDA #COL_WALL
                STA draw_color
                LDA #RADAR_X-2              ; bordo superiore
                STA px_x
                LDA #RADAR_Y-2
                STA px_y
                LDA #RADAR_W+4
                STA rect_w
                LDA #2
                STA rect_h
                JSR fill_rect
                LDA #RADAR_Y+RADAR_H        ; bordo inferiore
                STA px_y
                JSR fill_rect
                LDA #RADAR_Y-2              ; bordo sinistro
                STA px_y
                LDA #2
                STA rect_w
                LDA #RADAR_H+4
                STA rect_h
                JSR fill_rect
                LDA #RADAR_X+RADAR_W        ; bordo destro
                STA px_x
                JSR fill_rect
                LDX #radar_prev
                LDB #MAZE_W*MAZE_H
                LDA #$FF
dr_lp           STA ,X+
                DECB
                BNE dr_lp
                RTS

update_radar
                LDX #radar_new              ; azzera la mappa nuova
                LDB #MAZE_W*MAZE_H
                CLRA
ur_clr          STA ,X+
                DECB
                BNE ur_clr
                LDA phase
                BNE ur_cmp                  ; Worluk / Wizard: radar spento
                LDX #2
ur_mon          LDA actor_type,X
                CMPA #BURWOR
                BLO ur_nx
                CMPA #WIZARD
                BHI ur_nx
                LDA actor_y,X               ; indice cella = y*11 + x
                LDB #MAZE_W
                MUL
                ADDB actor_x,X
                LDY #radar_new
                LEAY B,Y
                LDB actor_type,X
                DECB
                LDU #actor_colors
                LDA B,U
                STA ,Y
ur_nx           LEAX 1,X
                CMPX #MAX_ACTORS
                BNE ur_mon
ur_cmp          LDX #radar_new              ; ridisegna le celle cambiate
                LDU #radar_prev
                CLR ur_cy
ur_row          CLR ur_cx
ur_col          LDA ,X+
                CMPA ,U
                BEQ ur_same
                STA ,U
                STA draw_color
                LDA ur_cx
                ASLA
                ASLA                        ; * RADAR_PX (4)
                ADDA #RADAR_X
                STA px_x
                LDA ur_cy
                LDB #RADAR_PY
                MUL
                ADDB #RADAR_Y
                STB px_y
                LDA #RADAR_DW
                STA rect_w
                LDA #RADAR_DH
                STA rect_h
                PSHS X,U
                JSR fill_rect
                PULS X,U
ur_same         LEAU 1,U
                INC ur_cx
                LDA ur_cx
                CMPA #MAZE_W
                BNE ur_col
                INC ur_cy
                LDA ur_cy
                CMPA #MAZE_H
                BNE ur_row
                RTS

; calc_px_x: A = indice colonna, B = offset px -> px_x. Clobbera A,B,tmp2.
calc_px_x
                STB tmp2
                LDB #CELL_W
                MUL
                ADDB tmp2
                ADDB #MAZE_OX
                STB px_x
                RTS

; calc_px_y: A = indice riga, B = offset px -> px_y. Clobbera A,B,tmp2.
calc_px_y
                STB tmp2
                LDB #CELL_H
                MUL
                ADDB tmp2
                ADDB #MAZE_OY
                STB px_y
                RTS

; calc_actor_px: X = attore -> px_x/px_y = angolo in alto a sinistra dello sprite
;   px_x = MAZE_OX + x*CELL_W + sx*2 + ACT_OX    px_y = MAZE_OY + y*CELL_H + sy*4 + ACT_OY
calc_actor_px
                LDA actor_x,X
                LDB #CELL_W
                MUL
                STB px_x
                LDA actor_sx,X
                ASLA
                ADDA px_x
                ADDA #MAZE_OX+ACT_OX
                STA px_x
                LDA actor_y,X
                LDB #CELL_H
                MUL
                STB px_y
                LDA actor_sy,X
                ASLA
                ASLA
                ADDA px_y
                ADDA #MAZE_OY+ACT_OY
                STA px_y
                RTS

; calc_bullet_px: X = attore -> px_x/px_y della pallottola
calc_bullet_px
                LDA bullet_x,X
                LDB #CELL_W
                MUL
                STB px_x
                LDA bullet_sx,X
                ASLA
                ADDA px_x
                ADDA #MAZE_OX+BUL_OX
                STA px_x
                LDA bullet_y,X
                LDB #CELL_H
                MUL
                STB px_y
                LDA bullet_sy,X
                ASLA
                ASLA
                ADDA px_y
                ADDA #MAZE_OY+BUL_OY
                STA px_y
                RTS

; Cancella lo sprite nella posizione precedente (prev_px/py) se si e' spostato o
; e' morto.
; erase_actors: lo sprite e' opaco, quindi dopo uno spostamento basta cancellare la
; STRISCIA che il nuovo sprite lascia scoperta (niente rettangolo nero intero = niente
; sfarfallio). Cancellazione completa solo per morte, teleport warp o salti grandi.
erase_actors
                CLR actual_actor
ea_loop         LDX #0
                LDB actual_actor
                ABX
                LDA prev_px,X
                CMPA #$FF
                LBEQ ea_next
                LDA actor_type,X
                CMPA #DEAD
                LBEQ ea_full
                LDA actor_inv,X
                LBNE ea_full                ; invisibile: via lo sprite
                JSR calc_actor_px
                LDA px_x
                SUBA prev_px,X
                STA ea_dx
                LDA px_y
                SUBA prev_py,X
                STA ea_dy
                ORA ea_dx
                LBEQ ea_next                ; fermo e vivo: niente da cancellare
                LDA ea_dx
                BEQ ea_vert
                LDA ea_dy
                BNE ea_full                 ; diagonale: non previsto
                LDA ea_dx
                BPL ea_hpos
                NEGA                        ; verso sinistra: striscia a destra del nuovo
                CMPA #ACT_W
                BHS ea_full
                STA rect_w
                LDA px_x
                ADDA #ACT_W
                BRA ea_hgo
ea_hpos         CMPA #ACT_W                 ; verso destra: striscia a sinistra del vecchio
                BHS ea_full
                STA rect_w
                LDA prev_px,X
ea_hgo          STA px_x
                LDA prev_py,X
                STA px_y
                LDA #ACT_H
                STA rect_h
                BRA ea_do
ea_vert         LDA ea_dy
                BPL ea_vpos
                NEGA                        ; verso l'alto: striscia sotto il nuovo
                CMPA #ACT_H
                BHS ea_full
                STA rect_h
                LDA px_y
                ADDA #ACT_H
                BRA ea_vgo
ea_vpos         CMPA #ACT_H                 ; verso il basso: striscia sopra il vecchio
                BHS ea_full
                STA rect_h
                LDA prev_py,X
ea_vgo          STA px_y
                LDA prev_px,X
                STA px_x
                LDA #ACT_W
                STA rect_w
                BRA ea_do
ea_full         LDA prev_px,X
                STA px_x
                LDA prev_py,X
                STA px_y
                LDA #ACT_W
                STA rect_w
                LDA #ACT_H
                STA rect_h
ea_do           LDA #COL_FLOOR
                STA draw_color
                JSR fill_rect
                LDA actor_type,X
                CMPA #DEAD
                BEQ ea_clr
                LDA actor_inv,X
                BEQ ea_next
ea_clr          LDA #$FF
                STA prev_px,X
ea_next         INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                LBNE ea_loop
                RTS

erase_bullets
                CLR actual_actor
eb_loop         LDX #0
                LDB actual_actor
                ABX
                LDA prev_firing,X
                BEQ eb_next
                LDA firing,X
                BPL eb_erase                ; non piu' attiva
                JSR calc_bullet_px
                LDA px_x
                CMPA prev_bpx,X
                BNE eb_erase
                LDA px_y
                CMPA prev_bpy,X
                BEQ eb_next                 ; ferma e attiva: niente da cancellare
eb_erase                        LDA #COL_FLOOR
                STA draw_color
                LDA prev_bpx,X
                STA px_x
                LDA prev_bpy,X
                STA px_y
                LDA #BUL_W
                STA rect_w
                LDA #BUL_H
                STA rect_h
                JSR fill_rect
eb_next         INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                BNE eb_loop
                RTS

; draw_maze: disegna le linee del reticolo dalle maschere. Per ogni cella: W e N;
; in piu' E sull'ultima colonna e S sull'ultima riga. (Ogni muro e' definito su
; entrambe le celle adiacenti: verificato su tutti i 25 layout.)
draw_maze
                LDA #COL_WALL
                STA draw_color
                CLR dm_r
dm_row          CLR dm_c
dm_col          LDA dm_r
                LDB #MAZE_W
                MUL
                ADDB dm_c
                ADCA #0
                TFR D,U
                LDA maze,U
                STA dm_m
                BITA #WALL_W
                BEQ dm_n
                LDA dm_c
                LDB dm_r
                JSR vbar
dm_n            LDA dm_m
                BITA #WALL_N
                BEQ dm_e
                LDA dm_c
                LDB dm_r
                JSR hbar
dm_e            LDA dm_c
                CMPA #MAZE_W-1
                BNE dm_s
                LDA dm_m
                BITA #WALL_E
                BEQ dm_s
                LDA #MAZE_W
                LDB dm_r
                JSR vbar
dm_s            LDA dm_r
                CMPA #MAZE_H-1
                BNE dm_next
                LDA dm_m
                BITA #WALL_S
                BEQ dm_next
                LDA dm_c
                LDB #MAZE_H
                JSR hbar
dm_next         INC dm_c
                LDA dm_c
                CMPA #MAZE_W
                BNE dm_col
                INC dm_r
                LDA dm_r
                CMPA #MAZE_H
                BNE dm_row
                RTS

; vbar: A = indice colonna del reticolo (0..11), B = riga cella -> barra verticale
vbar            STB dm_t
                LDB #0
                JSR calc_px_x
                LDA dm_t
                LDB #0
                JSR calc_px_y
                LDA #BAR_W
                STA rect_w
                LDA #CELL_H+BAR_H
                STA rect_h
                JSR fill_rect
                RTS

; hbar: A = colonna cella, B = indice riga del reticolo (0..6) -> barra orizzontale
hbar            STB dm_t
                LDB #0
                JSR calc_px_x
                LDA dm_t
                LDB #0
                JSR calc_px_y
                LDA #CELL_W+BAR_W
                STA rect_w
                LDA #BAR_H
                STA rect_h
                JSR fill_rect
                RTS

; draw_lives: vite extra rimaste di P1 (a destra) e P2 (a sinistra) sopra i punteggi HUD
draw_lives
                LDA #LIVES_X
                STA px_x
                LDA #LIVES_Y
                STA px_y
                LDA #COL_FLOOR
                STA draw_color
                LDA #48
                STA rect_w
                LDA #ACT_H
                STA rect_h
                JSR fill_rect
                LDA #LIVES2_X
                STA px_x
                JSR fill_rect
                TST lives
                BLE dl_p2
                LDA lives
                CMPA #3
                BLS dl_ok1
                LDA #3
dl_ok1          STA dl_n
                LDA #SPR_LIFE
                LDB #36
                MUL
                ADDD #spr_00
                STD bl_base
                LDA #COL_P1
                STA draw_color
                LDA #LIVES_X
                STA px_x
                LDA #LIVES_Y
                STA px_y
dl_lp1          JSR blit_sprite
                LDA px_x
                ADDA #16
                STA px_x
                DEC dl_n
                BNE dl_lp1
dl_p2           TST lives2
                BLE dl_end
                LDA lives2
                CMPA #3
                BLS dl_ok2
                LDA #3
dl_ok2          STA dl_n
                LDA #SPR_LIFE_P2
                LDB #36
                MUL
                ADDD #spr_00
                STD bl_base
                LDA #COL_P2
                STA draw_color
                LDA #LIVES2_X
                STA px_x
                LDA #LIVES_Y
                STA px_y
dl_lp2          JSR blit_sprite
                LDA px_x
                ADDA #16
                STA px_x
                DEC dl_n
                BNE dl_lp2
dl_end          RTS

draw_actors
                CLR actual_actor
da_loop         LDX #0
                LDB actual_actor
                ABX
                LDA actor_type,X
                CMPA #DEAD
                BEQ da_next
da_draw         LDA actor_inv,X
                BNE da_next                 ; invisibile: non si disegna
                LDA actor_dying,X
                BEQ da_norm
                LDA #COL_BOOM
                BRA da_col
da_norm         LDA actor_type,X
                DECA
                LDY #actor_colors
                LDA A,Y
da_col          STA draw_color
                CMPX #2
                BHS da_go
                LDA p_invul,X               ; P1/P2 appena rinato: lampeggia
                ANDA #2
                BEQ da_go
                LDA #COL_BULLET
                STA draw_color
da_go
                JSR calc_actor_px
                JSR get_sprite_ptr
                JSR blit_sprite
                LDA px_x                    ; ricorda dove e' stato disegnato
                STA prev_px,X
                LDA px_y
                STA prev_py,X
da_next         INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                BNE da_loop
                RTS

; get_sprite_ptr: X = attore -> bl_base = indirizzo dello sprite (36 byte).
;   direzione: 0 sx, 1 dx, 2 su, 3 giu (da actor_fx/fy); id = spr_base_tbl[(tipo-1)*4+dir]
;   + fotogramma (actor_anim/2); indirizzo = spr_00 + id*36. Clobbera A,B,Y.
get_sprite_ptr
                LDA actor_dying,X
                BEQ gs_norm
                LSRA                        ; esplosione: due fotogrammi alternati
                LSRA
                ANDA #1
                ADDA #SPR_BOOM
                BRA gs_id
gs_norm         LDA actor_fx,X
                BEQ gs_vert
                BMI gs_left
                LDB #1
                BRA gs_dir
gs_left         CLRB
                BRA gs_dir
gs_vert         LDB #2
                LDA actor_fy,X
                BMI gs_dir
                LDB #3
gs_dir          PSHS B
                LDA actor_type,X
                DECA
                ASLA
                ASLA
                ADDA ,S+                    ; A = (tipo-1)*4 + direzione
                LDY #spr_base_tbl
                LDA A,Y
                STA tmp1
                LDA actor_anim,X
                LSRA
                ADDA tmp1                   ; A = id sprite
gs_id           LDB #36
                MUL
                ADDD #spr_00
                STD bl_base
                RTS

; blit_sprite: disegna lo sprite bl_base (18 righe x 12 px) in px_x (PARI), px_y con
; il colore draw_color. Preserva X,Y,U.
;   1) decodifica: ogni nibble (4 px) -> 2 byte-coppia (0,1,$10,$11) -> bl_buf, 6 per riga
;   2) colonna-coppia c = px_x/2 -> banco (c AND 1: 0=A), byte c/2. Con odd = c0 AND 1:
;      banco A: primo byte i0+odd, prima coppia = odd ; banco B: primo byte i0, prima
;      coppia = odd XOR 1 ; ogni banco riceve 3 coppie (k, k+2, k+4).
blit_sprite
                PSHS X,Y,U
                LDA draw_color
                STA bl_col
                ; pre-calcolo pattern*colore (4 MUL per sprite): mul_tbl indicizzata dal
                ; valore del pattern ($00,$01,$10,$11) -> bl_pass non usa MUL nel ciclo caldo
                CLR mul_tbl
                LDA #$01
                LDB bl_col
                MUL
                STB mul_tbl+$01
                LDA #$10
                LDB bl_col
                MUL
                STB mul_tbl+$10
                LDA #$11
                LDB bl_col
                MUL
                STB mul_tbl+$11
                LDX bl_base
                LDY #bl_buf
                LDU #nib_tbl
                LDA #18
                STA bl_rows
bl_dec          LDB ,X
                LSRB
                LSRB
                LSRB
                LSRB
                ASLB
                LDD B,U
                STD ,Y++
                LDB ,X+
                ANDB #$0F
                ASLB
                LDD B,U
                STD ,Y++
                LDB ,X+
                LSRB
                LSRB
                LSRB
                LSRB
                ASLB
                LDD B,U
                STD ,Y++
                DEC bl_rows
                BNE bl_dec
                LDA px_y
                LDB #VRAM_STRIDE
                MUL
                ADDD #VRAM
                STD bl_vbase
                LDA px_x
                LSRA                        ; c0 = colonna-coppia
                TFR A,B
                ANDB #1                     ; B = odd
                LSRA                        ; A = i0
                STA bl_ib
                STB bl_ka
                ADDB bl_ib
                STB bl_ia
                LDA bl_ka
                EORA #1
                STA bl_kb
                JSR sel_bank_a
                LDA bl_ia
                LDB bl_ka
                BSR bl_pass
                JSR sel_bank_b
                LDA bl_ib
                LDB bl_kb
                BSR bl_pass
                PULS X,Y,U,PC

; bl_pass: A = byte iniziale nella riga, B = prima coppia (0/1) -> scrive 3 byte x 18
; righe nel banco selezionato, con la tabella mul_tbl (nessun MUL nel ciclo).
bl_pass
                STA bl_off
                LDU #mul_tbl                ; U e' salvato/ripristinato da blit_sprite
                LDX #bl_buf
                ABX                         ; X = buffer + prima coppia
                LDY bl_vbase
                LDB bl_off
                LEAY B,Y                    ; Y = prima riga, primo byte
                LDA #18
                STA bl_rows
bp_row          LDA ,X                      ; pattern coppia 0
                LDA A,U
                STA ,Y
                LDA 2,X                     ; pattern coppia 2
                LDA A,U
                STA 1,Y
                LDA 4,X                     ; pattern coppia 4
                LDA A,U
                STA 2,Y
                LEAX 6,X
                LEAY VRAM_STRIDE,Y
                LDA bl_rows
                BITA #1
                BNE bp_ns
                JSR dac_step                ; mantiene il flusso audio DAC 6-bit continuo durante il disegno
bp_ns           DEC bl_rows
                BNE bp_row
                RTS

draw_bullets
                CLR actual_actor
db_loop         LDX #0
                LDB actual_actor
                ABX
                LDA firing,X
                BPL db_next
                LDA #COL_BULLET
                CMPX #2
                BLO db_col
                LDA #COL_MBULLET            ; pallottole dei mostri: rosse
db_col          STA draw_color
                JSR calc_bullet_px
                LDA #BUL_W
                STA rect_w
                LDA #BUL_H
                STA rect_h
                JSR fill_rect
                LDA px_x
                STA prev_bpx,X
                LDA px_y
                STA prev_bpy,X
                LDA #1
                STA prev_firing,X
                BRA db_adv
db_next         CLR prev_firing,X
db_adv          INC actual_actor
                LDA actual_actor
                CMPA #MAX_ACTORS
                BNE db_loop
                RTS

;-------------------------------------------------------------------------------
; fill_rect (bitmap16) - invariata rispetto alla v3 (verificata sul modello).
;   IN : px_x (PARI), px_y, rect_w (PARI), rect_h, draw_color
;   OUT: preserva X, Y, px_x, px_y.
;-------------------------------------------------------------------------------
fill_rect
                PSHS X,Y
                LDA draw_color
                STA fr_t
                LSLA
                LSLA
                LSLA
                LSLA
                ADDA fr_t
                STA byte_color
                LDA px_y
                LDB #VRAM_STRIDE
                MUL
                ADDD #VRAM
                STD fr_base
                LDA rect_w
                LSRA
                STA fr_n
                LDA px_x
                LSRA
                LSRA
                BCS fr_c0odd
                STA fr_sa
                STA fr_sb
                LDA fr_n
                INCA
                LSRA
                STA fr_ca
                LDA fr_n
                LSRA
                STA fr_cb
                BRA fr_go
fr_c0odd        STA fr_sb
                INCA
                STA fr_sa
                LDA fr_n
                LSRA
                STA fr_ca
                LDA fr_n
                INCA
                LSRA
                STA fr_cb
fr_go
                LDB fr_ca
                BEQ fr_skipa
                JSR sel_bank_a
                LDA fr_sa
                LDB fr_ca
                BSR fr_pass
fr_skipa        LDB fr_cb
                BEQ fr_done
                JSR sel_bank_b
                LDA fr_sb
                LDB fr_cb
                BSR fr_pass
fr_done         PULS X,Y,PC

fr_pass
                STB fr_cnt
                LDX fr_base
                LEAX A,X
                LDA rect_h
                STA fr_rows
                LDA byte_color
fp_row          LEAY ,X
                LDB fr_cnt
fp_col          STA ,X+
                DECB
                BNE fp_col
                LEAX VRAM_STRIDE,Y
                DEC fr_rows
                BNE fp_row
                RTS

; install_irq: aggancia il vettore del task di interrupt ($2061). irq_tick conta i tick e
; prosegue con la routine originale (che riconosce l'IRQ e fa RTI/RTS come prima).
; Se in $2061 c'e' un JMP esteso ($7E) si aggancia l'operando in $2062.
install_irq
                PSHS CC
                ORCC #$10                   ; IRQ mascherati durante la modifica
                LDX #IRQ_VEC
                LDA ,X
                CMPA #$7E
                BNE ii_ptr
                LEAX 1,X
ii_ptr          LDD ,X
                STD old_irq
                LDD #irq_tick
                STD ,X
                CLR tick
                CLR last_tick
                LDA #FRAME_TICKS
                STA frame_dt
                PULS CC,PC                  ; ripristina lo stato precedente degli IRQ

irq_tick        INC tick
                JSR snd_tick
                JMP [old_irq]

; wait_frame: attende FRAME_TICKS tick dall'ultimo frame generando nel frattempo
; l'audio polifonico sul DAC a 6 bit ($A7CD) tramite dac_step, ed esegue l'animazione
; della paletta dei muri per le fasi Worluk (lampeggio rosso/blu) e Wizard (muri bianchi).
wait_frame
                ; Aggiorna il colore dei muri (indice paletta 1 = byte 2,3) SOLO quando cambia stato:
                LDA phase
                BEQ wf_chk
                CMPA #1
                BNE wf_w2
                LDB tick
                BITB #4
                BEQ wf_w1b
                LDA #1                      ; Worluk rosso
                BRA wf_chk
wf_w1b          LDA #2                      ; Worluk blu scuro
                BRA wf_chk
wf_w2           LDA #3                      ; Wizard bianco
wf_chk          CMPA wall_col_st
                BEQ wf_wait
                STA wall_col_st
                LDB #2
                STB PAL_IDX
                TSTA
                BEQ wf_p0
                CMPA #1
                BEQ wf_p1
                CMPA #2
                BEQ wf_p1b
                LDA #$FF                    ; Fase 2 (Wizard of Wor): muri bianchi come sul C64
                LDB #$0F
                BRA wf_pset
wf_p1           LDA #$0F                    ; Fase 1a (Worluk): muri rosso vivo
                CLRB
                BRA wf_pset
wf_p1b          CLRA                        ; Fase 1b (Worluk): muri blu scuro
                LDB #$08
                BRA wf_pset
wf_p0           CLRA                        ; Fase 0 (normale): muri blu
                LDB #$0C
wf_pset         STA PAL_DATA
                STB PAL_DATA
wf_wait         LDY #WF_TIMEOUT
wf_lp           JSR dac_step
                LDA tick
                SUBA last_tick
                CMPA #FRAME_TICKS
                BHS wf_ok
                LEAY -1,Y
                BNE wf_lp
                INC tick
                JSR snd_tick
wf_ok           LDA tick
                SUBA last_tick
                STA frame_dt
                LDA tick
                STA last_tick
                LDA frame_dt                ; passi di simulazione dovuti: dt * SIM_HZ / 50
                CMPA #6
                BLS wf_c
                LDA #6
wf_c            LDB #SIM_HZ
                MUL
                ADDB sim_acc
                ADCA #0
                CLR sim_n
wf_sl           CMPD #SEC_TICKS
                BLO wf_sd
                SUBD #SEC_TICKS
                INC sim_n
                BRA wf_sl
wf_sd           STB sim_acc
                LDA sim_n
                CMPA #2
                BLS wf_end
                LDA #2
                STA sim_n                   ; massimo 2 passi per frame (movimento fluido e costante)
wf_end          RTS

;-------------------------------------------------------------------------------
; MOTORE AUDIO DOPPIO: DAC 6-BIT NATIVO ($A7CD) + SCHEDA SN76489 ($A7FF)
;   - Il DAC 6-bit ($A7CD, sempre attivo su DCMOTO senza configurazione) riproduce in tempo
;     reale tramite dac_step:
;       * Tutte le 20 tracce SFX C64 (2 voci ad onda impulsiva/quadra + generatore LFSR di
;         rumore a 12 frequenze + modulazione filtro SID per spari, esplosioni, Worluk, Wizard)
;       * Il basso ostinato C64 a 3 note con inviluppo staccato fedele (AD=$0A, SR=$00)
;       * I jingle polifonici a 3 voci (jg_play)
;   - In parallelo, snd_tick pilota anche la scheda SN76489 ($A7FF) a 50 Hz.
;-------------------------------------------------------------------------------
snd_init
                PSHS D
                LDA JOY_CRA
                ANDA #$FB                   ; seleziona DDRA ($A7CC)
                STA JOY_CRA
                CLR JOY_PRA                 ; DDRA = $00 (tutti ingressi: direzioni Joy 0 e 1)
                ORA #$04                    ; seleziona PRA
                STA JOY_CRA
                LDA JOY_CRB
                ANDA #$FB                   ; seleziona DDRB ($A7CD)
                STA JOY_CRB
                LDB #$3F                    ; DDRB = $3F (bit 0-5 = DAC 6-bit out, bit 6-7 = Fire in)
                STB JOY_PRB
                ORA #$04                    ; seleziona PRB
                STA JOY_CRB
                LDD #$ACE1
                STD dac_lfsr
                CLR sim_n
                CLR sim_acc
                CLR mus_speed
                JSR snd_silence
                PULS D,PC

; snd_silence: ferma effetti e musica e muta sia il DAC ($A7CD) che l'SN76489 ($A7FF)
snd_silence
                PSHS CC,D
                ORCC #$10
                CLR JOY_PRB                 ; DAC 6-bit a riposo (0)
                CLR snd_left
                CLR snd_cur
                CLR snd_chain
                CLR mus_on
                CLR dac_volA
                CLR dac_volB
                CLR dac_volN
                CLR dac_volM
                CLRA
                CLRB
                STD dac_incA
                STD dac_incB
                STD dac_incM
                LDA #$9F                    ; muta i 4 canali SN76489
                JSR sn_out
                LDA #$BF
                JSR sn_out
                LDA #$DF
                JSR sn_out
                LDA #$FF
                JSR sn_out
                PULS CC,D,PC

; sn_out: invia il byte in A alla scheda audio SN76489 ($A7FF); preserva A
sn_out          STA SN_PORT
                NOP
                NOP
                RTS

; sn_per: D = periodo 10 bit -> canale con comando di latch snd_chb ($80/$A0/$C0). Preserva X.
sn_per
                PSHS D
                ANDB #$0F
                ORB snd_chb
                TFR B,A
                JSR sn_out                  ; latch + 4 bit bassi
                LDD ,S                      ; periodo originale
                LSRA
                RORB
                LSRA
                RORB
                LSRA
                RORB
                LSRA
                RORB                        ; B = periodo >> 4
                ANDB #$3F
                TFR B,A
                JSR sn_out                  ; 6 bit alti
                PULS D,PC

; per_to_inc: converte il periodo SN76489 in D (0..1023) nell'incremento di fase 16-bit per il DAC.
; Preserva X.
per_to_inc
                PSHS X
                CMPD #255
                BLS pti_lu
                LSRA
                RORB
                LSRA
                RORB
                ASLB
                ROLA
                LDX #inc_tbl
                LDD D,X
                LSRA
                RORB
                LSRA
                RORB
                PULS X,PC
pti_lu          ASLB
                ROLA
                LDX #inc_tbl
                LDD D,X
                PULS X,PC

; dac_step: passo del sintetizzatore DAC a 6 bit ($A7CD) per SFX C64 (2 voci + rumore LFSR a 12
; frequenze) e basso ostinato staccato. Usa SOLO A e B (preserva X, Y, U).
dac_step
                LDA snd_left
                BEQ ds_mus
                CLRB
                LDA dac_volA
                BEQ ds_vb
                LDD dac_phA
                ADDD dac_incA
                STD dac_phA
                CLRB
                TSTA
                BPL ds_vb
                LDB dac_volA
ds_vb           STB dac_tmp
                LDA dac_volB
                BEQ ds_vn
                LDD dac_phB
                ADDD dac_incB
                STD dac_phB
                TSTA
                BPL ds_vn
                LDB dac_tmp
                ADDB dac_volB
                STB dac_tmp
ds_vn           LDA dac_volN
                BEQ ds_out
                DEC dac_cntN
                BPL ds_n_hold
                LDA dac_perN
                STA dac_cntN
                LDD dac_lfsr
                LSRA
                RORB
                BCC ds_n_ns
                EORA #$B4
ds_n_ns         STD dac_lfsr
ds_n_hold       LDA dac_lfsr+1
                BITA #1
                BEQ ds_out
                LDB dac_tmp
                ADDB dac_volN
                STB dac_tmp
ds_out          LDB dac_tmp
                CMPB #63
                BLS ds_w
                LDB #63
ds_w            STB JOY_PRB
                RTS
ds_mus          LDA mus_on
                BEQ ds_sil
                LDA dac_volM
                BEQ ds_sil
                LDD dac_phM
                ADDD dac_incM
                STD dac_phM
                CLRB
                CMPA #$40                   ; onda impulsiva C64 (duty cycle 25%)
                BHS ds_mw
                LDB dac_volM
ds_mw           STB JOY_PRB
                RTS
ds_sil           RTS

; snd_play: A = priorita' effetto (0 MONSTER_SHOOTS .. 11 WIZARD_KILLED); come il C64 un effetto
; parte solo se la sua priorita' e' >= di quella dell'effetto in corso.
snd_play
                PSHS CC,D,X
                ORCC #$10
                CMPA snd_cur
                BLO sp_end
                STA snd_cur
                LDX #sfx_prio
                LDB A,X                     ; B = indice effetto (id C64 - 1)
                JSR sfx_start
sp_end          PULS CC,D,X,PC

; sfx_start: B = indice effetto 0..19. Spegne i canali effetto, e la musica se serve.
sfx_start
                PSHS D,X
                LDX #sfx_stopm
                LDA B,X
                BEQ ss_nm
                CLR mus_on                  ; l'effetto a due voci spegne il basso (come sul C64)
                CLR dac_volM
                LDA #$DF
                JSR sn_out
ss_nm           CLR dac_volA
                CLR dac_volB
                CLR dac_volN
                CLRA
                CLRB
                STD dac_incA
                STD dac_incB
                LDA #$9F                    ; azzera lo stato dei canali effetto SN76489
                JSR sn_out
                LDA #$BF
                JSR sn_out
                LDA #$FF
                JSR sn_out
                LDB 1,S                     ; ripristina B = indice effetto 0..19
                ASLB
                ASLB                        ; 4 byte per effetto
                LDX #sfx_tab
                ABX
                LDD ,X
                STD snd_ptr
                LDA 2,X
                STA snd_left
                LDA 3,X
                STA snd_chain
                PULS D,X,PC

; mus_start: avvia il basso ostinato C64 (3 note, velocita' in funzione del dungeon)
mus_start
                PSHS CC,A
                ORCC #$10
                CLR mus_idx
                CLR mus_cnt
                CLR mus_age
                LDA current_dungeon
                CMPA #8
                BLO ms_s
                LDA #7
ms_s            EORA #7
                INCA
                STA mus_speed
                ASLA
                ASLA
                STA mus_dur
                LDA #1
                STA mus_on
                PULS CC,A,PC

; mus_faster: la musica accelera quando la porta warp si riapre (DEC music_speed, minimo 1)
mus_faster
                PSHS A
                LDA mus_speed
                DECA
                BNE mf_s
                INCA
mf_s            STA mus_speed
                ASLA
                ASLA
                STA mus_dur
                PULS A,PC

; snd_tick: chiamato a 50 Hz dall'IRQ (e da wait_frame se l'IRQ manca): aggiorna i parametri
; sia del sintetizzatore DAC 6-bit ($A7CD) che della scheda SN76489 ($A7FF).
snd_tick
                PSHS D,X,U
                LDA snd_left
                LBEQ st_chk
                LDX snd_ptr
                LDA ,X+
                STA snd_hdr
                BITA #1
                BEQ st_pb
                LDA #$80
                STA snd_chb
                LDD ,X++
                JSR sn_per                  ; periodo canale 0 SN76489
                JSR per_to_inc
                STD dac_incA                ; incremento fase voce A DAC
                LDA snd_hdr
st_pb           BITA #2
                BEQ st_att
                LDA #$A0
                STA snd_chb
                LDD ,X++
                JSR sn_per                  ; periodo canale 1 SN76489
                JSR per_to_inc
                STD dac_incB                ; incremento fase voce B DAC
                LDA snd_hdr
st_att          BITA #4
                BEQ st_noi
                LDB ,X+
                STB snd_chb
                TFR B,A
                LSRA
                LSRA
                LSRA
                LSRA
                LDU #att_to_vol
                LDB A,U
                STB dac_volA                ; volume voce A DAC
                ORA #$90
                JSR sn_out                  ; attenuazione canale 0 SN76489
                LDB snd_chb
                ANDB #$0F
                LDA B,U
                STA dac_volB                ; volume voce B DAC
                TFR B,A
                ORA #$B0
                JSR sn_out                  ; attenuazione canale 1 SN76489
                LDA snd_hdr
st_noi          BITA #8
                BEQ st_fin
                LDB ,X+
                STB snd_chb
                TFR B,A
                ANDA #$0F                   ; 0..11: passo frequenza rumore C64
                STA dac_perN
                CMPA #2
                BLS st_nsn
                LDA #2
st_nsn          ORA #$E4                    ; rumore bianco SN76489, velocita' 0..2
                JSR sn_out
                LDB snd_chb
                LSRB
                LSRB
                LSRB
                LSRB
                LDU #att_to_vol
                LDA B,U
                STA dac_volN                ; volume rumore DAC
                TFR B,A
                ORA #$F0
                JSR sn_out                  ; attenuazione rumore SN76489
st_fin          STX snd_ptr
                DEC snd_left
                BNE st_mus
                CLR snd_cur                 ; effetto finito: libero (come end_of_sfx)
                LDB snd_chain
                BEQ st_off
                DECB                        ; effetto concatenato (come i byte finali dei dati C64)
                JSR sfx_start
                BRA st_mus
st_off          CLR dac_volA
                CLR dac_volB
                CLR dac_volN
                LDA #$9F
                JSR sn_out
                LDA #$BF
                JSR sn_out
                LDA #$FF
                JSR sn_out
                BRA st_mus
st_chk          LDB snd_chain               ; nessun frame in corso: eventuale catena
                BEQ st_mus
                DECB
                JSR sfx_start
st_mus          LDA mus_on
                BEQ st_end
                LDA mus_cnt
                BNE st_mn
                LDA #$C0                    ; nuova nota: periodo sul canale 2
                STA snd_chb
                LDA mus_idx
                ASLA
                LDX #mus_per
                LDD A,X
                JSR sn_per
                JSR per_to_inc
                STD dac_incM                ; frequenza nota basso ostinato sul DAC
                INC mus_idx
                LDA mus_idx
                CMPA #3
                BLO st_m1
                CLR mus_idx
st_m1           LDA mus_dur
                STA mus_cnt
                CLR mus_age
st_mn           LDA mus_age
                CMPA #16
                BLS st_ma
                LDA #16
st_ma           LDX #mus_dac_env
                LDB A,X
                STB dac_volM                ; inviluppo staccato morbido sul DAC
                LDX #mus_env
                LDA A,X
                ADDA #MUS_ATT
                CMPA #15
                BLS st_mo
                LDA #15
st_mo           ORA #$D0
                JSR sn_out                  ; attenuazione canale 2 SN76489
                INC mus_age
                DEC mus_cnt
st_end          PULS D,X,U,PC

;-------------------------------------------------------------------------------
; jg_play: sintetizzatore polifonico C64 SID a 3 voci per i jingle (X = pattern)
;   Ogni riga: [durata_60Hz, nota1, nota2, nota3], terminato da $00.
;   Ciclo interno a 128 cicli esatti (7812.5 Hz) 100% privo di diramazioni condizionali
;   e con IRQ mascherati: zero jitter di fase e zero distorsione sul DAC a 6 bit ($A7CD).
;-------------------------------------------------------------------------------
jg_play
                PSHS CC,D,X,Y,U
                ORCC #$10                   ; maschera IRQ durante il jingle per eliminare ogni distorsione
                LDD #0
                STD jg_p1
                STD jg_p2
                STD jg_p3
jg_row          LDA ,X+
                LBEQ jg_done
                STA jg_dur
                LDA ,X+                     ; Voce 1 (Sawtooth C64)
                LDB #$FF
                TSTA
                BNE jg_m1
                CLRB
jg_m1           STB jg_msk1                 ; $FF se nota attiva, $00 se pausa
                ASLA
                LDY #snd_freq
                LDD A,Y
                STD jg_b1
                STD jg_i1
                LDA ,X+                     ; Voce 2 (Pulse C64)
                ASLA
                LDD A,Y
                STD jg_b2
                STD jg_i2
                LDA ,X+                     ; Voce 3 (Pulse C64)
                ASLA
                LDD A,Y
                STD jg_b3
                STD jg_i3
jg_tick         LDA #130                    ; 130 * 128 cicli = 16.64 ms (1 tick C64 a 60 Hz)
                STA jg_scnt
                ; --- Ciclo campione a 128 cicli COSTANTI (nessun branch condizionale sulle voci) ---
jg_smp          LDD jg_p1                   ; 5c - Voce 1: Dente di sega (0..25)
                ADDD jg_i1                  ; 6c
                STD jg_p1                   ; 5c
                ANDA jg_msk1                ; 4c - 0 se pausa
                LSRA                        ; 2c - 0..127
                LSRA                        ; 2c - 0..63
                LSRA                        ; 2c - 0..31
                STA jg_mix                  ; 4c
                LSRA                        ; 2c - 0..15
                LSRA                        ; 2c - 0..7
                NEGA                        ; 2c
                ADDA jg_mix                 ; 4c - 0..25
                STA jg_mix                  ; 4c (totale V1 = 44c)
                LDD jg_p2                   ; 5c - Voce 2: Onda quadra (0 o 16) senza branch
                ADDD jg_i2                  ; 6c
                STD jg_p2                   ; 5c
                ANDA #$80                   ; 2c - $00 o $80
                LSRA                        ; 2c - $00 o $40
                LSRA                        ; 2c - $00 o $20
                LSRA                        ; 2c - $00 o $10 (0 o 16)
                ADDA jg_mix                 ; 4c
                STA jg_mix                  ; 4c (totale V2 = 32c)
                LDD jg_p3                   ; 5c - Voce 3: Onda quadra (0 o 16) senza branch
                ADDD jg_i3                  ; 6c
                STD jg_p3                   ; 5c
                ANDA #$80                   ; 2c - $00 o $80
                LSRA                        ; 2c - $00 o $40
                LSRA                        ; 2c - $00 o $20
                LSRA                        ; 2c - $00 o $10 (0 o 16)
                ADDA jg_mix                 ; 4c - somma finale 0..57 (mai in clipping sul DAC 0..63)
                STA JOY_PRB                 ; 5c - scrive sul DAC a 6 bit ($A7CD) (totale V3 = 33c)
                NOP                         ; 2c - padding esatto a 128 cicli totali
                NOP                         ; 2c
                NOP                         ; 2c
                NOP                         ; 2c
                NOP                         ; 2c
                DEC jg_scnt                 ; 6c
                BNE jg_smp                  ; 3c (44 + 32 + 33 + 19 = 128 cicli esatti = 7812.5 Hz)
                DEC jg_dur
                LBEQ jg_row
                ; Vibrato C64 (identico a play_sound_pattern: indicizzato da jg_dur AND 7)
                LDA jg_dur
                ANDA #7
                LDY #snd_vibrato_tbl
                LDB A,Y
                CLRA
                STD jg_vib
                LDD jg_b1
                BEQ jg_vb2
                ADDD jg_vib
                STD jg_i1
jg_vb2          LDD jg_b2
                BEQ jg_vb3
                ADDD jg_vib
                STD jg_i2
jg_vb3          LDD jg_b3
                LBEQ jg_tick
                ADDD jg_vib
                STD jg_i3
                LBRA jg_tick
jg_done         CLR JOY_PRB
                LDA tick
                STA last_tick
                PULS CC,D,X,Y,U,PC

; Tabella frequenze C64 SID (F_SID / 2 per accumulatore a 16 bit @ 7812.5 Hz = Hz esatti C64)
snd_freq
                FDB $0000                   ; 0 = pausa
                FDB $02CC                   ; 1 = SID $0598 (84.0 Hz, E2)
                FDB $0324                   ; 2 = SID $0647 (94.3 Hz, F#2)
                FDB $0386                   ; 3 = SID $070C (105.9 Hz, G#2)
                FDB $0548                   ; 4 = SID $0A8F (158.6 Hz, D#3)
                FDB $0598                   ; 5 = SID $0B30 (168.0 Hz, E3)
                FDB $070C                   ; 6 = SID $0E18 (211.7 Hz, G#3)
                FDB $08E2                   ; 7 = SID $11C3 (266.8 Hz, C4)
                FDB $0969                   ; 8 = SID $12D1 (282.6 Hz, C#4)
                FDB $0A90                   ; 9 = SID $151F (317.2 Hz, D#4)
                FDB $0B30                   ; 10 = SID $1660 (336.1 Hz, E4)
                FDB $0D4E                   ; 11 = SID $1A9C (399.7 Hz, G4)
                FDB $0862                   ; 12 = SID $10C3 (251.8 Hz, B3)

; Tabella vibrato C64 SID (valori C64 $00,$14,$3C,$64,$78,$64,$3C,$14 divisi per 2)
snd_vibrato_tbl
                FCB $00,$0A,$1E,$32,$3C,$32,$1E,$0A

; Pattern musicali C64 (estratti fedelmente da wizard_of_wor_c64.asm, sintassi lwasm senza spazi)
; Jingle 1a: "GET READY" (accordo iniziale prima di "GO")
snd_pat_1a      FCB $3F,1,6,8
                FCB $00
; Jingle 1b: "GO" (fanfara di risoluzione)
snd_pat_1b      FCB $15,2,4,9
                FCB $2A,3,5,10
                FCB $34,1,6,8
                FCB $15,0,0,0
                FCB $00
; Jingle 1 completo (usato nella sequenza di Game Over come sul C64)
snd_pattern_1   FCB $3F,1,6,8
                FCB $15,2,4,9
                FCB $2A,3,5,10
                FCB $34,1,6,8
                FCB $15,0,0,0
                FCB $00
; Jingle 2: "DOUBLE SCORE DUNGEON" / "BONUS WORRIOR"
snd_pattern_2   FCB $C8,3,12,11
                FCB $00
; Jingle 3: "GAME OVER"
snd_pattern_3   FCB $54,3,8,10
                FCB $54,3,7,9
                FCB $00

; ===== TRACCE SFX C64 (emulazione fedele di sfx.play di dabadab/wizardofwor a 50 Hz per DAC $A7CD + SN76489 $A7FF) =====
; frame di 20 ms: header (bit0 perA, bit1 perB, bit2 att, bit3 rumore: i campi sono presenti solo se cambiati),
; poi perA(2) perB(2) attA*16+attB, attN*16+rateN (att 15 = canale spento)
sfxd_01
                FCB $05,$01,$85,$1F
                FCB $01,$00,$8E
                FCB $01,$01,$58
                FCB $01,$00,$88
                FCB $01,$01,$34
                FCB $01,$00,$82
                FCB $01,$00,$7F
                FCB $01,$01,$0B
                FCB $01,$00,$7A
                FCB $01,$00,$F5
                FCB $01,$00,$75
                FCB $01,$00,$73
                FCB $01,$00,$DA
                FCB $01,$00,$6F
                FCB $01,$00,$CB
                FCB $01,$00,$6B
                FCB $01,$00,$69
                FCB $01,$00,$B8
                FCB $01,$00,$65
                FCB $01,$00,$AD
                FCB $01,$00,$62
                FCB $01,$00,$60
                FCB $01,$00,$9F
                FCB $01,$00,$5D
                FCB $01,$00,$97
                FCB $01,$00,$5A
                FCB $04,$FF
sfxd_02
                FCB $05,$01,$01,$0F
                FCB $01,$00,$FE
                FCB $01,$00,$FB
                FCB $01,$00,$F9
                FCB $01,$00,$A1
                FCB $01,$00,$A0
                FCB $01,$00,$9F
                FCB $01,$00,$EF
                FCB $01,$00,$EC
                FCB $01,$00,$EA
                FCB $01,$00,$9B
                FCB $01,$00,$9A
                FCB $01,$00,$99
                FCB $01,$00,$E1
                FCB $01,$00,$DF
                FCB $01,$00,$DD
                FCB $01,$00,$95
                FCB $01,$00,$94
                FCB $01,$00,$93
                FCB $01,$00,$D5
                FCB $01,$00,$D3
                FCB $01,$00,$D1
                FCB $01,$00,$90
                FCB $01,$00,$8F
                FCB $01,$00,$8E
                FCB $01,$00,$8D
                FCB $01,$00,$C8
                FCB $01,$00,$C7
                FCB $01,$00,$C5
                FCB $01,$00,$8A
                FCB $01,$00,$89
                FCB $01,$00,$88
                FCB $01,$00,$BF
                FCB $01,$00,$BD
                FCB $01,$00,$BB
                FCB $01,$00,$85
                FCB $01,$00,$84
                FCB $00
                FCB $01,$00,$B6
                FCB $01,$00,$B4
                FCB $01,$00,$B3
                FCB $01,$00,$81
                FCB $01,$00,$80
                FCB $01,$00,$7F
                FCB $01,$00,$AE
                FCB $01,$00,$AD
                FCB $01,$00,$AB
                FCB $01,$00,$AA
                FCB $01,$00,$7C
                FCB $01,$00,$7B
                FCB $00
                FCB $01,$00,$FF
                FCB $04,$FF
sfxd_03
                FCB $0D,$02,$50,$2F,$0B
                FCB $09,$01,$9D,$05
                FCB $01,$01,$BC
                FCB $01,$01,$E1
                FCB $01,$02,$0C
                FCB $09,$02,$3E,$06
                FCB $0D,$02,$7C,$3F,$16
                FCB $09,$02,$C8,$17
                FCB $0D,$03,$28,$4F,$27
                FCB $01,$03,$70
                FCB $09,$03,$B6,$28
                FCB $0D,$02,$04,$5F,$38
                FCB $01,$02,$35
                FCB $01,$02,$51
                FCB $0D,$02,$71,$7F,$59
                FCB $01,$02,$93
                FCB $01,$02,$BA
                FCB $0D,$02,$E5,$8F,$69
                FCB $01,$03,$0C
                FCB $01,$03,$2C
                FCB $09,$03,$4F,$6A
                FCB $0D,$03,$67,$9F,$7A
                FCB $01,$03,$8F
                FCB $0D,$03,$9E,$AF,$8A
                FCB $01,$03,$BB
                FCB $01,$03,$CB
                FCB $01,$03,$DB
                FCB $01,$03,$EC
                FCB $0D,$02,$07,$BF,$9A
                FCB $01,$02,$11
                FCB $00
                FCB $0D,$02,$1A,$CF,$AA
                FCB $09,$02,$24,$AB
                FCB $00
                FCB $0D,$02,$2E,$DF,$BB
                FCB $01,$02,$39
                FCB $00
                FCB $01,$02,$44
                FCB $0C,$FF,$FB
sfxd_04
                FCB $05,$01,$A8,$1F
                FCB $01,$01,$96
                FCB $01,$01,$86
                FCB $01,$01,$78
                FCB $01,$01,$68
                FCB $01,$01,$5B
                FCB $01,$01,$4F
                FCB $01,$01,$43
                FCB $01,$01,$38
                FCB $01,$01,$2F
                FCB $01,$01,$26
                FCB $01,$01,$1C
                FCB $01,$01,$14
                FCB $01,$01,$0D
                FCB $01,$01,$05
                FCB $01,$00,$FE
                FCB $01,$00,$F8
                FCB $01,$00,$F1
                FCB $01,$00,$EB
                FCB $01,$00,$E5
                FCB $01,$00,$E0
                FCB $01,$00,$DA
                FCB $01,$00,$D6
                FCB $01,$00,$D1
                FCB $01,$00,$CD
                FCB $01,$00,$C8
                FCB $01,$00,$C4
                FCB $01,$00,$C0
                FCB $01,$00,$BC
                FCB $01,$00,$B9
                FCB $01,$00,$B5
                FCB $01,$00,$B2
                FCB $01,$00,$AE
                FCB $01,$00,$AB
                FCB $01,$00,$A8
                FCB $01,$00,$A5
                FCB $01,$00,$A2
                FCB $01,$00,$A0
                FCB $01,$00,$9D
                FCB $01,$00,$9A
                FCB $01,$00,$98
                FCB $04,$FF
sfxd_05
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$96,$4F,$21
                FCB $0D,$00,$F1,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F1,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F2,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F1,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F2,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F1,$6F,$43
                FCB $01,$01,$2A
                FCB $0D,$01,$36,$5F,$34
                FCB $0D,$00,$95,$4F,$21
                FCB $0D,$00,$F2,$6F,$43
                FCB $01,$01,$2A
                FCB $0C,$FF,$F3
sfxd_06
                FCB $05,$02,$6C,$1F
                FCB $01,$00,$DB
                FCB $01,$00,$72
                FCB $01,$00,$4D
                FCB $01,$00,$3A
                FCB $01,$00,$3B
                FCB $01,$00,$3D
                FCB $01,$00,$40
                FCB $01,$00,$43
                FCB $01,$00,$46
                FCB $01,$00,$4A
                FCB $01,$00,$4E
                FCB $01,$00,$52
                FCB $01,$00,$57
                FCB $01,$00,$5C
                FCB $01,$00,$63
                FCB $01,$00,$6A
                FCB $01,$00,$72
                FCB $01,$00,$7B
                FCB $01,$00,$86
                FCB $01,$00,$93
                FCB $01,$00,$9D
                FCB $01,$00,$A5
                FCB $01,$00,$AF
                FCB $01,$00,$BA
                FCB $01,$00,$C6
                FCB $01,$00,$D5
                FCB $01,$00,$E5
                FCB $01,$00,$F8
                FCB $01,$01,$01
                FCB $01,$01,$0F
                FCB $01,$01,$19
                FCB $01,$01,$2A
                FCB $01,$01,$36
                FCB $01,$01,$4B
                FCB $01,$01,$5A
                FCB $01,$01,$74
                FCB $01,$01,$88
                FCB $01,$01,$A9
                FCB $01,$01,$C3
                FCB $01,$01,$E0
                FCB $01,$01,$F0
                FCB $01,$02,$01
                FCB $01,$02,$13
                FCB $01,$02,$3C
                FCB $01,$02,$53
                FCB $01,$02,$6C
                FCB $01,$02,$87
                FCB $01,$02,$C5
                FCB $01,$02,$E8
                FCB $00
                FCB $01,$03,$0F
                FCB $01,$03,$3B
                FCB $00
                FCB $01,$03,$6B
                FCB $01,$03,$A2
                FCB $00
                FCB $01,$03,$E0
                FCB $00
                FCB $01,$02,$13
                FCB $01,$02,$3C
                FCB $00
                FCB $01,$02,$6C
                FCB $00
                FCB $00
                FCB $01,$02,$A4
                FCB $00
                FCB $00
                FCB $01,$02,$E8
                FCB $00
                FCB $00
                FCB $01,$03,$3B
                FCB $00
                FCB $00
                FCB $01,$03,$A2
                FCB $00
                FCB $00
                FCB $01,$02,$13
                FCB $00
                FCB $00
                FCB $04,$FF
sfxd_07
                FCB $05,$00,$AF,$0F
                FCB $01,$00,$92
                FCB $04,$FF
                FCB $05,$00,$8E,$0F
                FCB $04,$FF
                FCB $05,$00,$8B,$0F
                FCB $01,$00,$89
                FCB $04,$FF
                FCB $05,$00,$86,$0F
                FCB $04,$FF
                FCB $05,$00,$83,$0F
                FCB $01,$00,$82
                FCB $04,$FF
                FCB $05,$00,$93,$0F
                FCB $04,$FF
                FCB $05,$00,$92,$0F
                FCB $01,$00,$90
                FCB $04,$FF
                FCB $05,$00,$8D,$0F
                FCB $04,$FF
                FCB $05,$00,$89,$0F
                FCB $01,$00,$88
                FCB $04,$FF
                FCB $05,$00,$85,$0F
                FCB $04,$FF
                FCB $05,$00,$82,$0F
                FCB $01,$00,$80
                FCB $04,$FF
                FCB $05,$00,$94,$0F
                FCB $04,$FF
                FCB $05,$00,$90,$0F
                FCB $01,$00,$8E
                FCB $04,$FF
                FCB $05,$00,$8B,$0F
                FCB $04,$FF
                FCB $05,$00,$88,$0F
                FCB $01,$00,$86
                FCB $04,$FF
                FCB $05,$00,$83,$0F
                FCB $04,$FF
                FCB $05,$00,$80,$0F
                FCB $01,$00,$93
                FCB $04,$FF
sfxd_08
sfxd_09
                FCB $0D,$03,$A2,$3F,$0A
                FCB $09,$03,$0F,$09
                FCB $01,$02,$A4
                FCB $09,$02,$53,$08
                FCB $01,$02,$0A
                FCB $01,$03,$B1
                FCB $09,$03,$5F,$07
                FCB $01,$03,$0F
                FCB $01,$02,$D6
                FCB $09,$02,$A4,$06
                FCB $01,$02,$79
                FCB $01,$02,$4D
                FCB $01,$02,$2C
                FCB $09,$02,$0F,$05
                FCB $01,$01,$F0
                FCB $01,$01,$D8
                FCB $01,$01,$C3
                FCB $01,$01,$AF
                FCB $01,$01,$9B
                FCB $09,$01,$8A,$04
                FCB $01,$01,$7B
                FCB $01,$01,$6B
                FCB $01,$01,$5E
                FCB $01,$01,$52
                FCB $01,$01,$47
                FCB $01,$01,$3B
                FCB $09,$01,$31,$03
                FCB $01,$01,$28
                FCB $01,$01,$1E
                FCB $01,$01,$16
                FCB $01,$01,$0F
                FCB $01,$01,$07
                FCB $01,$00,$FF
                FCB $01,$00,$F9
                FCB $01,$00,$F3
                FCB $01,$00,$EC
                FCB $09,$00,$E7,$02
                FCB $01,$00,$E1
                FCB $01,$00,$DC
                FCB $01,$00,$D7
                FCB $01,$00,$D2
                FCB $01,$00,$D5
                FCB $01,$00,$E7
                FCB $09,$00,$FA,$03
                FCB $01,$01,$11
                FCB $01,$01,$2D
                FCB $09,$01,$4E,$04
                FCB $01,$01,$79
                FCB $09,$01,$AF,$05
                FCB $01,$01,$E8
                FCB $01,$02,$18
                FCB $09,$02,$4D,$06
                FCB $01,$02,$8E
                FCB $01,$02,$C5
                FCB $09,$02,$F1,$07
                FCB $01,$03,$24
                FCB $01,$03,$5F
                FCB $01,$03,$A2
                FCB $09,$03,$F1,$08
                FCB $01,$02,$13
                FCB $01,$02,$27
                FCB $01,$02,$48
                FCB $01,$02,$5F
                FCB $09,$02,$87,$09
                FCB $01,$02,$95
                FCB $01,$02,$A4
                FCB $01,$02,$B4
                FCB $01,$02,$D6
                FCB $01,$02,$E8
                FCB $01,$02,$FB
                FCB $01,$03,$0F
                FCB $01,$03,$24
                FCB $00
                FCB $09,$03,$3B,$0A
                FCB $01,$03,$52
                FCB $00
                FCB $01,$03,$6B
                FCB $01,$03,$86
                FCB $00
                FCB $01,$03,$A2
                FCB $09,$03,$0F,$09
                FCB $01,$02,$A4
                FCB $09,$02,$48,$08
                FCB $01,$02,$0A
                FCB $01,$03,$B1
                FCB $09,$03,$5F,$07
                FCB $01,$03,$0F
                FCB $01,$02,$D6
                FCB $09,$02,$A4,$06
                FCB $01,$02,$73
                FCB $01,$02,$4D
                FCB $01,$02,$2C
                FCB $09,$02,$0F,$05
                FCB $01,$01,$F0
                FCB $01,$01,$D8
                FCB $01,$01,$C3
                FCB $01,$01,$AC
                FCB $01,$01,$9B
                FCB $09,$01,$8A,$04
                FCB $01,$01,$7B
                FCB $01,$01,$6B
                FCB $01,$01,$5E
                FCB $01,$01,$52
                FCB $01,$01,$45
                FCB $01,$01,$3B
                FCB $09,$01,$31,$03
                FCB $01,$01,$28
                FCB $01,$01,$1E
                FCB $01,$01,$16
                FCB $01,$01,$0F
sfxd_10
                FCB $0D,$03,$A2,$3F,$0A
                FCB $0C,$FF,$FA
sfxd_11
                FCB $0D,$03,$A2,$5F,$3A
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $0D,$03,$52,$3F,$37
                FCB $01,$03,$41
                FCB $01,$03,$2F
                FCB $01,$03,$1C
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$02,$D2,$3F,$37
                FCB $01,$02,$C5
                FCB $01,$02,$B6
                FCB $01,$02,$AA
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$02,$73,$3F,$37
                FCB $01,$02,$67
                FCB $01,$02,$5E
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$02,$32,$3F,$36
                FCB $01,$02,$28
                FCB $01,$02,$21
                FCB $01,$02,$19
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$EB,$3F,$36
                FCB $01,$03,$DE
                FCB $01,$03,$D2
                FCB $01,$03,$C6
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $0D,$03,$C0,$3F,$36
                FCB $01,$03,$D4
                FCB $01,$03,$E8
                FCB $01,$03,$FE
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$02,$3E,$3F,$37
                FCB $01,$02,$4C
                FCB $01,$02,$5B
                FCB $01,$02,$6A
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$02,$B8,$3F,$37
                FCB $01,$02,$C3
                FCB $01,$02,$CD
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$05,$3F,$37
                FCB $01,$03,$0A
                FCB $01,$03,$12
                FCB $01,$03,$1A
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$3B,$3F,$37
                FCB $01,$03,$43
                FCB $01,$03,$49
                FCB $01,$03,$4F
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$62,$3F,$37
                FCB $01,$03,$68
                FCB $01,$03,$6B
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$78,$3F,$37
                FCB $01,$03,$7C
                FCB $01,$03,$7F
                FCB $00
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$89,$3F,$37
                FCB $01,$03,$8D
                FCB $01,$03,$90
                FCB $00
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $0D,$03,$94,$3F,$37
                FCB $01,$03,$97
                FCB $00
                FCB $00
                FCB $0C,$FF,$3B
                FCB $00
                FCB $00
                FCB $00
                FCB $0D,$03,$9E,$3F,$37
                FCB $00
                FCB $01,$03,$A2
                FCB $00
                FCB $0C,$FF,$3B
                FCB $08,$FB
sfxd_12
                FCB $07,$00,$7A,$00,$7C,$00
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$77,$00,$79,$00
                FCB $03,$00,$76,$00,$78
                FCB $04,$FF
                FCB $00
                FCB $00
                FCB $07,$00,$77,$00,$79,$00
                FCB $03,$00,$76,$00,$78
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$77,$00,$79,$00
                FCB $00
                FCB $03,$00,$76,$00,$78
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$77,$00,$79,$00
                FCB $00
                FCB $03,$00,$76,$00,$78
                FCB $04,$FF
sfxd_13
                FCB $07,$03,$A2,$00,$3A,$00
                FCB $03,$00,$53,$00,$22
                FCB $03,$00,$9C,$00,$2B
                FCB $03,$00,$66,$00,$25
                FCB $03,$00,$BC,$00,$2D
                FCB $03,$00,$65,$00,$25
                FCB $03,$00,$A6,$00,$2B
                FCB $03,$01,$B6,$00,$34
                FCB $03,$00,$89,$00,$29
                FCB $03,$01,$0F,$00,$30
                FCB $03,$00,$72,$00,$27
                FCB $03,$00,$BF,$00,$2D
                FCB $03,$02,$48,$00,$35
                FCB $04,$FF
sfxd_14
                FCB $05,$03,$A2,$0F
                FCB $04,$FF
                FCB $07,$00,$A4,$00,$A8,$00
                FCB $04,$FF
                FCB $07,$00,$81,$00,$83,$00
                FCB $04,$FF
sfxd_15
sfxd_16
sfxd_17
                FCB $0D,$00,$8B,$0F,$04
                FCB $09,$00,$7F,$03
                FCB $01,$00,$75
                FCB $09,$00,$6C,$02
                FCB $01,$00,$6E
                FCB $09,$00,$76,$03
                FCB $01,$00,$7F
                FCB $01,$00,$82
                FCB $01,$00,$77
                FCB $09,$00,$6E,$02
                FCB $01,$00,$66
                FCB $01,$00,$6D
                FCB $09,$00,$75,$03
                FCB $01,$00,$7E
                FCB $01,$00,$7A
                FCB $09,$00,$70,$02
                FCB $01,$00,$68
                FCB $01,$00,$66
                FCB $01,$00,$6C
                FCB $09,$00,$74,$03
                FCB $01,$00,$7C
                FCB $09,$00,$73,$02
                FCB $01,$00,$6A
                FCB $09,$00,$63,$01
                FCB $09,$00,$65,$02
                FCB $01,$00,$6B
                FCB $01,$00,$73
                FCB $09,$00,$75,$03
                FCB $09,$00,$6C,$02
                FCB $01,$00,$65
                FCB $09,$00,$5E,$01
                FCB $09,$00,$64,$02
                FCB $01,$00,$6A
                FCB $01,$00,$72
                FCB $01,$00,$6E
                FCB $01,$00,$67
                FCB $09,$00,$60,$01
                FCB $01,$00,$5D
                FCB $01,$00,$63
                FCB $09,$00,$69,$02
                FCB $01,$00,$71
                FCB $01,$00,$69
                FCB $09,$00,$62,$01
                FCB $01,$00,$5B
                FCB $01,$00,$5D
                FCB $01,$00,$62
                FCB $09,$00,$68,$02
                FCB $01,$00,$6B
                FCB $09,$00,$63,$01
                FCB $01,$00,$5D
                FCB $01,$00,$57
                FCB $01,$00,$5C
                FCB $01,$00,$63
                FCB $09,$00,$6B,$02
                FCB $01,$00,$69
                FCB $01,$00,$64
                FCB $09,$00,$5E,$01
                FCB $01,$00,$5D
                FCB $09,$00,$64,$02
                FCB $01,$00,$6C
                FCB $09,$00,$75,$03
                FCB $09,$00,$6E,$02
                FCB $01,$00,$67
                FCB $09,$00,$62,$01
                FCB $09,$00,$65,$02
                FCB $01,$00,$6C
                FCB $09,$00,$76,$03
                FCB $01,$00,$7A
                FCB $09,$00,$72,$02
                FCB $01,$00,$6B
                FCB $01,$00,$64
                FCB $01,$00,$6B
                FCB $09,$00,$74,$03
                FCB $01,$00,$7E
                FCB $01,$00,$7C
                FCB $09,$00,$73,$02
                FCB $01,$00,$6B
                FCB $01,$00,$69
                FCB $01,$00,$71
                FCB $09,$00,$7A,$03
                FCB $09,$00,$84,$04
                FCB $09,$00,$7B,$03
                FCB $09,$00,$72,$02
                FCB $01,$00,$6B
                FCB $01,$00,$6D
                FCB $09,$00,$75,$03
                FCB $01,$00,$7F
                FCB $09,$00,$84,$04
                FCB $09,$00,$79,$03
                FCB $09,$00,$71,$02
                FCB $01,$00,$69
                FCB $01,$00,$71
                FCB $09,$00,$7A,$03
                FCB $09,$00,$84,$04
                FCB $09,$00,$81,$03
                FCB $01,$00,$77
                FCB $09,$00,$6F,$02
                FCB $01,$00,$6C
                FCB $09,$00,$74,$03
                FCB $01,$00,$7E
                FCB $09,$00,$89,$04
                FCB $09,$00,$7E,$03
                FCB $01,$00,$75
                FCB $09,$00,$6D,$02
                FCB $01,$00,$6F
                FCB $09,$00,$78,$03
                FCB $01,$00,$82
                FCB $09,$00,$86,$04
                FCB $09,$00,$7C,$03
                FCB $09,$00,$73,$02
                FCB $01,$00,$6B
                FCB $01,$00,$72
                FCB $09,$00,$7B,$03
                FCB $09,$00,$86,$04
                FCB $09,$00,$83,$03
                FCB $01,$00,$79
                FCB $09,$00,$70,$02
                FCB $01,$00,$6D
                FCB $09,$00,$75,$03
                FCB $01,$00,$7F
                FCB $09,$00,$8A,$04
                FCB $09,$00,$80,$03
                FCB $01,$00,$76
                FCB $09,$00,$6E,$02
                FCB $01,$00,$70
                FCB $09,$00,$79,$03
                FCB $01,$00,$83
                FCB $09,$00,$87,$04
                FCB $09,$00,$7B,$03
                FCB $09,$00,$72,$02
                FCB $01,$00,$69
                FCB $01,$00,$70
                FCB $09,$00,$78,$03
                FCB $01,$00,$81
                FCB $01,$00,$7E
                FCB $01,$00,$74
                FCB $09,$00,$6B,$02
                FCB $01,$00,$68
                FCB $01,$00,$6F
                FCB $09,$00,$77,$03
                FCB $01,$00,$80
                FCB $01,$00,$76
                FCB $09,$00,$6E,$02
                FCB $01,$00,$66
                FCB $01,$00,$67
                FCB $01,$00,$6E
                FCB $09,$00,$76,$03
                FCB $01,$00,$79
                FCB $09,$00,$70,$02
                FCB $01,$00,$68
                FCB $09,$00,$61,$01
                FCB $09,$00,$66,$02
                FCB $01,$00,$6D
                FCB $09,$00,$75,$03
                FCB $09,$00,$72,$02
                FCB $01,$00,$6A
                FCB $09,$00,$63,$01
                FCB $01,$00,$60
                FCB $09,$00,$65,$02
                FCB $01,$00,$6C
                FCB $09,$00,$74,$03
                FCB $09,$00,$6C,$02
                FCB $01,$00,$64
                FCB $09,$00,$5E,$01
                FCB $01,$00,$5F
                FCB $09,$00,$65,$02
                FCB $01,$00,$6B
                FCB $01,$00,$6E
                FCB $01,$00,$66
                FCB $09,$00,$5F,$01
                FCB $01,$00,$5A
                FCB $01,$00,$5E
                FCB $09,$00,$64,$02
                FCB $01,$00,$6A
                FCB $01,$00,$68
                FCB $09,$00,$61,$01
                FCB $01,$00,$5B
                FCB $01,$00,$59
                FCB $01,$00,$5F
                FCB $09,$00,$66,$02
                FCB $01,$00,$6E
                FCB $01,$00,$68
                FCB $09,$00,$63,$01
                FCB $01,$00,$5D
                FCB $01,$00,$60
                FCB $09,$00,$67,$02
                FCB $01,$00,$6F
                FCB $09,$00,$74,$03
                FCB $09,$00,$6D,$02
                FCB $01,$00,$66
                FCB $09,$00,$61,$01
                FCB $09,$00,$68,$02
                FCB $01,$00,$70
                FCB $09,$00,$7A,$03
                FCB $01,$00,$78
                FCB $09,$00,$70,$02
                FCB $01,$00,$69
                FCB $01,$00,$66
                FCB $01,$00,$6E
                FCB $09,$00,$77,$03
sfxd_18
                FCB $07,$00,$A5,$03,$0D,$11
                FCB $03,$00,$78,$01,$16
                FCB $04,$FF
                FCB $07,$00,$73,$00,$FF,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$6D,$00,$E2,$11
                FCB $04,$FF
                FCB $07,$00,$69,$00,$D2,$11
                FCB $03,$00,$67,$00,$CA
                FCB $04,$FF
                FCB $07,$00,$64,$00,$BD,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$7A,$01,$24,$11
                FCB $04,$FF
                FCB $07,$00,$75,$01,$0A,$11
                FCB $03,$00,$73,$00,$FF
                FCB $04,$FF
                FCB $07,$00,$6F,$00,$EB,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$69,$00,$D2,$11
                FCB $04,$FF
                FCB $07,$00,$65,$00,$C4,$11
                FCB $03,$00,$64,$00,$BD
                FCB $04,$FF
                FCB $07,$00,$7A,$01,$23,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$75,$01,$0A,$11
                FCB $04,$FF
                FCB $07,$00,$71,$00,$F4,$11
                FCB $03,$00,$6F,$00,$EB
                FCB $04,$FF
                FCB $07,$00,$6B,$00,$D9,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$65,$00,$C4,$11
                FCB $04,$FF
                FCB $07,$00,$62,$00,$B8,$11
                FCB $03,$00,$7A,$01,$23
                FCB $04,$FF
                FCB $07,$00,$78,$01,$16,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$71,$00,$F4,$11
                FCB $04,$FF
                FCB $07,$00,$6D,$00,$E2,$11
                FCB $03,$00,$6B,$00,$D9
                FCB $04,$FF
                FCB $07,$00,$67,$00,$CA,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$62,$00,$B8,$11
                FCB $04,$FF
                FCB $07,$00,$7A,$01,$24,$11
                FCB $03,$00,$78,$01,$16
                FCB $04,$FF
                FCB $07,$00,$73,$00,$FF,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$6D,$00,$E2,$11
                FCB $04,$FF
                FCB $07,$00,$69,$00,$D2,$11
                FCB $03,$00,$67,$00,$CA
                FCB $04,$FF
                FCB $07,$00,$64,$00,$BD,$11
                FCB $04,$FF
sfxd_19
                FCB $00
                FCB $07,$00,$79,$00,$79,$11
                FCB $04,$FF
                FCB $07,$00,$84,$00,$84,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$98,$00,$98,$11
                FCB $04,$FF
                FCB $07,$00,$A9,$00,$A9,$11
                FCB $03,$00,$AF,$00,$AF
                FCB $04,$FF
                FCB $07,$00,$BA,$00,$BA,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$C6,$00,$C6,$11
                FCB $04,$FF
                FCB $07,$00,$CD,$00,$CD,$11
                FCB $03,$00,$D1,$00,$D1
                FCB $04,$FF
                FCB $07,$00,$D6,$00,$D6,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$DC,$00,$DC,$11
                FCB $04,$FF
                FCB $07,$00,$DF,$00,$DF,$11
                FCB $03,$00,$E0,$00,$E0
                FCB $04,$FF
                FCB $07,$00,$E1,$00,$E1,$11
                FCB $04,$FF
                FCB $00
                FCB $07,$00,$E4,$00,$E4,$11
                FCB $04,$FF
                FCB $07,$00,$E6,$00,$E6,$11
                FCB $00
                FCB $04,$FF
                FCB $07,$00,$E8,$00,$E8,$11
                FCB $04,$FF
sfxd_20
                FCB $0D,$02,$E8,$2F,$09
                FCB $09,$02,$34,$06
                FCB $09,$01,$6C,$04
                FCB $0D,$02,$63,$3F,$16
                FCB $0D,$03,$B1,$4F,$28
                FCB $01,$02,$53
                FCB $09,$02,$9D,$29
                FCB $01,$02,$CD
                FCB $01,$02,$E8
                FCB $0D,$02,$32,$3F,$16
                FCB $09,$01,$6D,$14
                FCB $0D,$02,$66,$5F,$36
                FCB $0D,$03,$B1,$6F,$48
                FCB $01,$02,$53
                FCB $0D,$02,$9D,$7F,$59
                FCB $01,$02,$CD
                FCB $0D,$02,$E8,$6F,$49
                FCB $09,$02,$32,$46
                FCB $09,$01,$6D,$44
                FCB $0D,$02,$66,$7F,$56
                FCB $0D,$03,$B1,$8F,$68
                FCB $0D,$02,$53,$9F,$78
                FCB $09,$02,$9D,$79
                FCB $0D,$02,$CD,$AF,$89
                FCB $0C,$FF,$F9
; tabella effetti (id-1) x 4 byte: FDB tracce, FCB frame, FCB catena (id C64 o 0)
sfx_tab
                FDB sfxd_01
                FCB 27,0
                FDB sfxd_02
                FCB 53,3
                FDB sfxd_03
                FCB 39,0
                FDB sfxd_04
                FCB 42,0
                FDB sfxd_05
                FCB 29,0
                FDB sfxd_06
                FCB 81,0
                FDB sfxd_07
                FCB 43,0
                FDB sfxd_08
                FCB 0,0
                FDB sfxd_09
                FCB 110,10
                FDB sfxd_10
                FCB 2,9
                FDB sfxd_11
                FCB 117,0
                FDB sfxd_12
                FCB 21,13
                FDB sfxd_13
                FCB 14,14
                FDB sfxd_14
                FCB 6,0
                FDB sfxd_15
                FCB 0,0
                FDB sfxd_16
                FCB 0,0
                FDB sfxd_17
                FCB 200,0
                FDB sfxd_18
                FCB 69,19
                FDB sfxd_19
                FCB 37,0
                FDB sfxd_20
                FCB 25,0
; priorita (MONSTER_SHOOTS..WIZARD_KILLED) -> id effetto C64 - 1
sfx_prio        FCB 19,5,4,8,0,6,1,3,10,11,17,16
; effetti che spengono la musica di sottofondo (come sul C64: id >= 9 tranne $14)
sfx_stopm       FCB 0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,0
; inviluppo staccato del basso ostinato C64 (AD=$0A, SR=$00): attacco immediato e decadimento al silenzio
mus_env         FCB 2,3,4,5,6,7,8,9,10,11,12,13,14,15,15,15,15
mus_dac_env     FCB 13,12,10,9,8,7,6,5,4,3,2,1,0,0,0,0,0
; periodi delle 3 note del basso C64 ($0325,$0300,$0340)
mus_per         FDB 592,620,572
att_to_vol      FCB 22,20,18,16,14,12,11,9,8,7,6,5,4,3,2,0
; tabella di conversione esatta periodo SN76489 -> incremento fase 16-bit DAC
inc_tbl
                FDB $0000,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF
                FDB $7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF
                FDB $7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF
                FDB $7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF,$7FFF
                FDB $7FFF,$7F9D,$7BDC,$7852,$74FB,$71D1,$6ED2,$6BFB
                FDB $6948,$66B7,$6444,$61F0,$5FB6,$5D95,$5B8C,$599A
                FDB $57BC,$55F2,$543A,$5293,$50FC,$4F75,$4DFC,$4C91
                FDB $4B33,$49E2,$489C,$4760,$4630,$4509,$43EC,$42D8
                FDB $41CD,$40CA,$3FCE,$3EDB,$3DEE,$3D08,$3C29,$3B50
                FDB $3A7D,$39B0,$38E9,$3826,$3769,$36B1,$35FD,$354F
                FDB $34A4,$33FE,$335B,$32BD,$3222,$318B,$30F8,$3068
                FDB $2FDB,$2F51,$2ECB,$2E47,$2DC6,$2D48,$2CCD,$2C54
                FDB $2BDE,$2B6A,$2AF9,$2A8A,$2A1D,$29B2,$2949,$28E3
                FDB $287E,$281B,$27BB,$275B,$26FE,$26A3,$2649,$25F0
                FDB $259A,$2545,$24F1,$249F,$244E,$23FE,$23B0,$2363
                FDB $2318,$22CE,$2285,$223D,$21F6,$21B1,$216C,$2129
                FDB $20E6,$20A5,$2065,$2026,$1FE7,$1FAA,$1F6D,$1F32
                FDB $1EF7,$1EBD,$1E84,$1E4C,$1E15,$1DDE,$1DA8,$1D73
                FDB $1D3F,$1D0B,$1CD8,$1CA6,$1C74,$1C43,$1C13,$1BE4
                FDB $1BB5,$1B86,$1B58,$1B2B,$1AFF,$1AD3,$1AA7,$1A7C
                FDB $1A52,$1A28,$19FF,$19D6,$19AE,$1986,$195E,$1938
                FDB $1911,$18EB,$18C6,$18A1,$187C,$1858,$1834,$1810
                FDB $17ED,$17CB,$17A9,$1787,$1765,$1744,$1723,$1703
                FDB $16E3,$16C3,$16A4,$1685,$1666,$1648,$162A,$160C
                FDB $15EF,$15D2,$15B5,$1599,$157C,$1560,$1545,$1529
                FDB $150E,$14F4,$14D9,$14BF,$14A5,$148B,$1471,$1458
                FDB $143F,$1426,$140E,$13F5,$13DD,$13C5,$13AE,$1396
                FDB $137F,$1368,$1351,$133B,$1324,$130E,$12F8,$12E2
                FDB $12CD,$12B7,$12A2,$128D,$1278,$1264,$124F,$123B
                FDB $1227,$1213,$11FF,$11EC,$11D8,$11C5,$11B2,$119F
                FDB $118C,$1179,$1167,$1155,$1142,$1130,$111E,$110D
                FDB $10FB,$10EA,$10D8,$10C7,$10B6,$10A5,$1094,$1084

;===============================================================================
; SCHERMATA INIZIALE E HUD PUNTEGGI
;===============================================================================
COL_LR          EQU 10                  ; rosso chiaro del C64 (voce 10 della paletta)
TITLE_SECS      EQU 5                   ; secondi per schermata, come check_if_game_is_started
BOX_Y           EQU 170
BOX_W           EQU 40
BOX_H           EQU 28
BOX1_X          EQU 0                   ; riquadro P2 (colonne 0..9)
BOX2_X          EQU 116                 ; riquadro P1 (colonne 29..38)
SC_ROW          EQU 22                  ; riga di testo dei punteggi
SC1_COL         EQU 31                  ; P1: colonne 31..36
SC2_COL         EQU 2                   ; P2: colonne 2..7
HS_COL          EQU 16
SPR_TX          EQU 64                  ; x degli sprite nella tabella nemici (C64: 127 px / 2)

; hs_clear: azzera i 5 record dei punteggi massimi
hs_clear
                LDX #hs_tbl
                LDB #10
                CLRA
hc_lp           STA ,X+
                DECB
                BNE hc_lp
                RTS

; hs_insert: inserisce `score` (P1) e `score2` (P2, se 2 giocatori) nella classifica
hs_insert
                LDD score
                BSR hs_ins_one
                LDA two_players
                BEQ hsi_end
                LDD score2
                BSR hs_ins_one
hsi_end         RTS

hs_ins_one      STD nm_val
                LDX #hs_tbl
                CLR hs_i
hi_lp           LDD nm_val
                CMPD ,X
                BHS hi_ins
                LEAX 2,X
                INC hs_i
                LDA hs_i
                CMPA #5
                BNE hi_lp
                RTS                         ; piu' basso di tutti
hi_ins          LDU #hs_tbl+8               ; scorre i record sotto di uno
hi_sh           PSHS X
                CMPU ,S++                   ; U == X ? (posizione di inserimento raggiunta)
                BEQ hi_set
                LDD -2,U
                STD ,U
                LEAU -2,U
                BRA hi_sh
hi_set          LDD nm_val
                STD ,X
                RTS

;-------------------------------------------------------------------------------
; draw_text: X -> record [colore, riga, colonna, lunghezza, codici...]
; riga = riga di testo C64 (8 righe di schermo), colonna = byte di riga (0..39).
; Per ogni carattere: glifo 3x5 -> un byte nel banco A (px 0,1) e uno nel B (px 2,3).
;-------------------------------------------------------------------------------
draw_text
                PSHS X,Y,U
                LDA ,X+
                STA txt_col
                ASLA
                ASLA
                ASLA
                ASLA
                STA txt_hi
                LDA ,X+                     ; riga * 320 + VRAM
                LDB #5
                MUL
                CLRA
                ASLB
                ROLA
                ASLB
                ROLA
                ASLB
                ROLA
                ASLB
                ROLA
                ASLB
                ROLA
                ASLB
                ROLA
                ADDD #VRAM
                STD dt_vram
                LDB ,X+                     ; + colonna
                CLRA
                ADDD dt_vram
                STD dt_vram
                LDA ,X+
                STA dt_n
                STX dt_txt
dt_chr          LDX dt_txt
                LDA ,X+
                STX dt_txt
                LDB #5
                MUL
                ADDD #font_tbl
                STD dt_font
                CLR dt_bank
                JSR sel_bank_a
                BSR dt_pass
                LDA #1
                STA dt_bank
                JSR sel_bank_b
                BSR dt_pass
                LDD dt_vram
                ADDD #1
                STD dt_vram
                DEC dt_n
                BNE dt_chr
                PULS X,Y,U,PC

dt_pass         LDU dt_font
                LDY dt_vram
                LDA #5
                STA dt_r
dp_r            LDB ,U+
                CLRA
                TST dt_bank
                BNE dp_b
                BITB #4                     ; banco A: punti 0 e 1
                BEQ dp_1
                ORA txt_hi
dp_1            BITB #2
                BEQ dp_w
                ORA txt_col
                BRA dp_w
dp_b            BITB #1                     ; banco B: punto 2 (il 3 e' la spaziatura)
                BEQ dp_w
                ORA txt_hi
dp_w            STA ,Y
                STA 40,Y
                STA 80,Y
                LEAY 120,Y
                DEC dt_r
                BNE dp_r
                RTS

; draw_num: D = valore (0..65535), nm_color/nm_row/nm_col -> 6 caratteri allineati a destra
draw_num
                STD nm_val
                LDA #$25
                STA sn_rec+4
                LDX #sn_rec+5
                LDU #pow10
                CLR nm_lead
                LDA #4
                STA nm_k
dn_pl           CLR nm_d
dn_sub          LDD nm_val
                SUBD ,U
                BLO dn_dig
                STD nm_val
                INC nm_d
                BRA dn_sub
dn_dig          LEAU 2,U
                LDA nm_d
                BNE dn_nz
                TST nm_lead
                BNE dn_nz
                LDA #$25                    ; zero iniziale -> spazio
                BRA dn_st
dn_nz           LDB #1
                STB nm_lead
dn_st           STA ,X+
                DEC nm_k
                BNE dn_pl
                LDA nm_val+1                ; ultima cifra sempre visibile
                STA ,X
                LDA nm_color
                STA sn_rec
                LDA nm_row
                STA sn_rec+1
                LDA nm_col
                STA sn_rec+2
                LDA #6
                STA sn_rec+3
                LDX #sn_rec
                JMP draw_text

pow10           FDB 10000,1000,100,10

; box_at: A = x del riquadro; draw_color gia' impostato. Contorno spesso 2 px, 40 x 28.
box_at
                PSHS A
                STA px_x
                LDA #BOX_Y
                STA px_y
                LDA #BOX_W
                STA rect_w
                LDA #2
                STA rect_h
                JSR fill_rect               ; sopra
                LDA #BOX_Y+BOX_H-2
                STA px_y
                JSR fill_rect               ; sotto
                LDA #BOX_Y
                STA px_y
                LDA #2
                STA rect_w
                LDA #BOX_H
                STA rect_h
                JSR fill_rect               ; sinistra
                LDA ,S
                ADDA #BOX_W-2
                STA px_x
                JSR fill_rect               ; destra
                PULS A,PC

; draw_score_boxes: riquadri e punteggi di P2 (verde/blu, a sinistra) e P1 (giallo, a destra)
draw_score_boxes
                LDA #COL_P2
                TST two_players
                BNE dsb_c2
                LDA #COL_WALL
dsb_c2          STA draw_color
                LDA #BOX1_X
                BSR box_at
                LDA #COL_P1
                STA draw_color
                LDA #BOX2_X
                BSR box_at
; draw_hud_scores: aggiorna i punteggi live di P2 (a sinistra) e P1 (a destra) sotto le vite
draw_hud_scores
                PSHS D,X,Y,U
                LDA #SC_ROW
                STA nm_row
                LDA #COL_P2
                TST two_players
                BNE dhs_c2
                LDA #COL_WALL
dhs_c2          STA nm_color
                LDA #SC2_COL
                STA nm_col
                LDD score2
                JSR draw_num
                LDA #SC_ROW
                STA nm_row
                LDA #COL_P1
                STA nm_color
                LDA #SC1_COL
                STA nm_col
                LDD score
                JSR draw_num
                PULS D,X,Y,U,PC

draw_hiscores
                CLR hs_i
dh_lp           LDB hs_i
                LDX #hs_rows
                LDA B,X
                STA nm_row
                LDA #HS_COL
                STA nm_col
                LDA #COL_BURWOR
                STA nm_color
                LDB hs_i
                ASLB
                LDX #hs_tbl
                ABX
                LDD ,X
                JSR draw_num
                INC hs_i
                LDA hs_i
                CMPA #5
                BNE dh_lp
                RTS

; schermata 1: copyright, high scores, riquadri, GET READY
draw_title1
                JSR clear_screen
                LDX #tx_cp1
                JSR draw_text
                LDX #tx_cp2
                JSR draw_text
                LDX #tx_hs
                JSR draw_text
                LDX #tx_gr
                JSR draw_text
                JSR draw_score_boxes
                JMP draw_hiscores

; schermata 2: tabella dei nemici (testi + sprite)
draw_title2
                JSR clear_screen
                LDX #tx_e_tbl
                LDA #8
                STA ts_i
dt2_t           PSHS X
                LDX ,X
                JSR draw_text
                PULS X
                LEAX 2,X
                DEC ts_i
                BNE dt2_t
                LDX #ts_tbl
                LDA #7
                STA ts_i
dt2_s           LDA ,X+                     ; indice in spr_base_tbl (verso destra)
                LDY #spr_base_tbl
                LDA A,Y
                LDB #36
                MUL
                ADDD #spr_00
                STD bl_base
                LDA ,X+
                STA draw_color
                LDA ,X+                     ; riga di testo -> y = riga*8 - 2
                LDB #8
                MUL
                SUBB #2
                STB px_y
                LDA #SPR_TX
                STA px_x
                JSR blit_sprite
                DEC ts_i
                BNE dt2_s
                RTS

; title_wait: attende fino a 5 s; Fuoco P1 -> 1P (two_players=0), Fuoco P2 -> 2P (two_players=1)
title_wait
                CLR tw_cnt
tw_lp           JSR wait_frame
                JSR read_joystick
                LDA joy_fire
                BNE tw_1p
                LDA joy2_fire
                BNE tw_2p
                LDA tw_cnt
                ADDA frame_dt
                BCS tw_to                   ; evita wrap 8-bit se frame_dt sfora 255
                STA tw_cnt
                CMPA #SEC_TICKS*TITLE_SECS
                BLO tw_lp
tw_to           CLRA                        ; C=0: tempo scaduto
                RTS
tw_1p           CLR two_players
                COMA                        ; C=1: avvia partita 1P
                RTS
tw_2p           LDA #1
                STA two_players
                COMA                        ; C=1: avvia partita 2P
                RTS

; title_screen: ripete le due schermate finche' non si preme il fuoco di P1 o P2
title_screen
                JSR snd_silence
                LDA #100                    ; prima aspetta il rilascio del fuoco (max 100 frame)
                STA tw_cnt
ts_rel          JSR read_joystick
                LDA joy_fire
                ORA joy2_fire
                BEQ ts_loop
                JSR wait_frame
                DEC tw_cnt
                BNE ts_rel
ts_loop         JSR draw_title1
                JSR title_wait
                BCS ts_end
                JSR draw_title2
                JSR title_wait
                BCC ts_loop
ts_end          RTS

hs_rows         FCB 9,11,13,15,17

; font 3x5: 5 righe per glifo, bit2..bit0 = punti 0..2
font_tbl
                FCB 7,5,5,5,7              ; 00 0
                FCB 2,6,2,2,7              ; 01 1
                FCB 7,1,7,4,7              ; 02 2
                FCB 7,1,7,1,7              ; 03 3
                FCB 5,5,7,1,1              ; 04 4
                FCB 7,4,7,1,7              ; 05 5
                FCB 7,4,7,5,7              ; 06 6
                FCB 7,1,1,2,2              ; 07 7
                FCB 7,5,7,5,7              ; 08 8
                FCB 7,5,7,1,7              ; 09 9
                FCB 2,5,7,5,5              ; 0A A
                FCB 6,5,6,5,6              ; 0B B
                FCB 7,4,4,4,7              ; 0C C
                FCB 6,5,5,5,6              ; 0D D
                FCB 7,4,6,4,7              ; 0E E
                FCB 7,4,6,4,4              ; 0F F
                FCB 7,4,5,5,7              ; 10 G
                FCB 5,5,7,5,5              ; 11 H
                FCB 7,2,2,2,7              ; 12 I
                FCB 1,1,1,5,2              ; 13 J
                FCB 5,5,6,5,5              ; 14 K
                FCB 4,4,4,4,7              ; 15 L
                FCB 5,7,7,5,5              ; 16 M
                FCB 6,5,5,5,5              ; 17 N
                FCB 2,5,5,5,2              ; 18 O
                FCB 6,5,6,4,4              ; 19 P
                FCB 2,5,5,7,3              ; 1A Q
                FCB 6,5,6,5,5              ; 1B R
                FCB 3,4,2,1,6              ; 1C S
                FCB 7,2,2,2,2              ; 1D T
                FCB 5,5,5,5,7              ; 1E U
                FCB 5,5,5,5,2              ; 1F V
                FCB 5,5,7,7,5              ; 20 W
                FCB 5,5,2,5,5              ; 21 X
                FCB 5,5,2,2,2              ; 22 Y
                FCB 7,1,2,4,7              ; 23 Z
                FCB 0,0,0,0,0              ; 24 ?
                FCB 0,0,0,0,0              ; 25  
                FCB 0,0,0,0,2              ; 26 .
                FCB 2,4,4,4,2              ; 27 (
                FCB 2,1,1,1,2              ; 28 )

tx_cp1          FCB COL_BURWOR,1,8,23,39,12,40,1,9,8,0,37
                FCB 22,18,13,32,10,34,37,22,15,16,38,37
                FCB 12,24,38
tx_cp2          FCB COL_BURWOR,3,11,17,39,12,40,1,9,8,3,37
                FCB 12,24,22,22,24,13,24,27,14
tx_hs           FCB COL_LR,6,14,11,17,18,16,17,37,28,12,24
                FCB 27,14,28
tx_gr           FCB COL_LR,22,15,9,16,14,29,37,27,14,10,13
                FCB 34
; Testi schermate intermedie C64 (GET READY / GO / DOUBLE SCORE DUNGEON / BONUS / GAME OVER)
tx_dng          FCB COL_BURWOR,5,13,7,13,30,23,16,14,24,23
tx_gr_mid       FCB COL_P1,8,15,9,16,14,29,37,27,14,10,13,34
tx_go_mid       FCB COL_P1,11,19,2,16,24
tx_dbl1         FCB COL_P1,7,14,12,13,24,30,11,21,14,37,28,12,24,27,14
tx_dbl2         FCB COL_P1,10,16,7,13,30,23,16,14,24,23
tx_bonus        FCB COL_LR,13,13,13,11,24,23,30,28,37,32,24,27,27,18,24,27
tx_gameover     FCB COL_LR,9,15,9,16,10,22,14,37,24,31,14,27
tx_e0           FCB COL_BURWOR,1,7,24,37,11,30,27,32,24,27,37
                FCB 37,37,37,37,37,1,0,0,37,37,25,24
                FCB 18,23,29,28
tx_e1           FCB COL_P1,4,8,23,16,10,27,32,24,27,37,37
                FCB 37,37,37,37,2,0,0,37,37,25,24,18
                FCB 23,29,28
tx_e2           FCB COL_LR,7,7,24,29,17,24,27,32,24,27,37
                FCB 37,37,37,37,37,5,0,0,37,37,25,24
                FCB 18,23,29,28
tx_e3           FCB COL_BURWOR,10,7,24,32,24,27,27,18,24,27,37
                FCB 37,37,37,37,1,0,0,0,37,37,25,24
                FCB 18,23,29,28
tx_e4           FCB COL_P1,13,7,24,32,24,27,27,18,24,27,37
                FCB 37,37,37,37,1,0,0,0,37,37,25,24
                FCB 18,23,29,28
tx_e5           FCB COL_LR,16,8,23,32,24,27,21,30,20,37,37
                FCB 37,37,37,1,0,0,0,37,37,25,24,18
                FCB 23,29,28
tx_e6           FCB COL_LR,18,19,12,13,24,30,11,21,14,37,28
                FCB 12,24,27,14
tx_e7           FCB COL_P1,21,1,30,32,18,35,10,27,13,37,24
                FCB 15,37,32,24,27,37,37,37,37,37,2,5
                FCB 0,0,37,37,25,24,18,23,29,28
tx_e_tbl        FDB tx_e0,tx_e1,tx_e2,tx_e3,tx_e4,tx_e5,tx_e6,tx_e7
ts_tbl
                FCB 8,COL_BURWOR,1
                FCB 12,COL_GARWOR,4
                FCB 16,COL_THORWOR,7
                FCB 0,COL_P2,10
                FCB 4,COL_P1,13
                FCB 24,COL_WORLUK,16
                FCB 28,COL_WIZARD,21

;===============================================================================
; DATI
;===============================================================================
; Posizioni di partenza provvisorie dei 6 mostri (qualsiasi cella e' valida)
start_x         FCB 1,3,5,7,9,2
start_y         FCB 0,2,1,3,2,4

; specchio della maschera muri: W<->E (dungeon_block_mirror_pair_tbl del C64)
mirror_tbl      FCB $00,$04,$02,$06,$01,$05,$03,$07,$08,$0C,$0A,$0E,$09,$0D,$0B,$0F

; Paletta: 16 colori x 2 byte = (G<<4)|R, B
palette_data
                FCB $00,$00             ; 0 nero
                FCB $00,$0C             ; 1 blu (muri)
                FCB $FF,$00             ; 2 giallo (P1)
                FCB $F0,$00             ; 3 verde (P2)
                FCB $66,$0F             ; 4 azzurro (Burwor)
                FCB $8F,$00             ; 5 arancio (Garwor)
                FCB $0F,$00             ; 6 rosso (Thorwor)
                FCB $0F,$0F             ; 7 magenta (Worluk)
                FCB $FF,$0F             ; 8 bianco (pallottola)
                FCB $0A,$0F             ; 9 viola (Wizard)
                FCB $6C,$07             ; 10 rosso chiaro (testi della schermata iniziale)
                FCB $44,$04
                FCB $44,$04
                FCB $44,$04
                FCB $44,$04
                FCB $44,$04

; punti per tipo (tipo-3): Burwor, Garwor, Thorwor, -, Worluk, Wizard
score_tbl       FDB 100,200,500,0,1000,2500
; celle di spawn (come le 8 posizioni del C64)
spn_x           FCB 2,3,4,5,5,6,7,8
spn_y           FCB 0,1,2,3,4,5,0,4

; indicizzato da (actor_type-1): 1=P2 2=P1 3=Burwor 4=Garwor 5=Thorwor 6=- 7=Worluk 8=Wizard
actor_colors    FCB COL_P2,COL_P1,COL_BURWOR,COL_GARWOR,COL_THORWOR,COL_FLOOR,COL_WORLUK,COL_WIZARD

; Layout dei dungeon
layout_data
; GENERATO da wow_layouts.py - 25 layout x 18 byte (6x6 nibble, W=1 N=2 E=4 S=8)
; dati di riferimento dal disassemblato C64 di dabadab (licenza non dichiarata)
layout_0         FCB $36,$3A,$2A,$51,$C3,$0A,$80,$24,$1A,$34,$55,$12,$55,$10,$C5,$98,$C9,$A8
layout_1         FCB $3A,$63,$A2,$53,$80,$A0,$84,$30,$65,$38,$45,$55,$1A,$0C,$10,$9A,$8A,$CD
layout_2         FCB $3A,$63,$A2,$1A,$00,$20,$82,$C5,$55,$3C,$3C,$10,$1A,$C3,$45,$9A,$AC,$98
layout_3         FCB $3A,$63,$A2,$53,$08,$A0,$04,$1A,$65,$1C,$53,$80,$53,$80,$65,$98,$AC,$98
layout_4         FCB $3A,$A2,$2A,$1A,$2C,$1A,$82,$43,$82,$3C,$14,$30,$53,$C1,$45,$98,$AC,$98
layout_5         FCB $3A,$A6,$32,$53,$A8,$45,$84,$32,$80,$34,$51,$A8,$51,$00,$A2,$98,$C9,$A8
layout_6         FCB $3A,$22,$A2,$53,$84,$38,$84,$30,$0A,$38,$45,$92,$1A,$41,$28,$9A,$8C,$9A
layout_7         FCB $3A,$63,$2A,$1A,$45,$92,$86,$10,$28,$38,$C5,$1A,$1A,$20,$0A,$9A,$C9,$8A
layout_8         FCB $32,$22,$22,$55,$55,$55,$80,$49,$45,$34,$92,$00,$51,$61,$C5,$9C,$98,$A8
layout_9         FCB $36,$3A,$2A,$51,$43,$82,$8C,$59,$65,$32,$8A,$45,$51,$22,$08,$9C,$9C,$9A
layout_10        FCB $36,$3A,$2A,$51,$C3,$0A,$80,$24,$1A,$34,$55,$12,$55,$10,$C5,$98,$C9,$A8
layout_11        FCB $36,$3A,$2A,$51,$0A,$0A,$84,$16,$92,$34,$94,$38,$51,$20,$82,$98,$C9,$A8
layout_12        FCB $3A,$63,$A2,$1A,$84,$38,$82,$20,$02,$3C,$55,$55,$1A,$04,$90,$9A,$C9,$A8
layout_13        FCB $3A,$22,$A2,$53,$84,$38,$84,$30,$0A,$38,$45,$92,$1A,$41,$28,$9A,$8C,$9A
layout_14        FCB $3A,$63,$2A,$1A,$45,$92,$86,$10,$28,$38,$C5,$1A,$1A,$20,$0A,$9A,$8C,$9A
layout_15        FCB $32,$22,$A2,$1C,$90,$65,$06,$3C,$90,$59,$06,$30,$16,$98,$00,$98,$AA,$88
layout_16        FCB $32,$22,$22,$51,$45,$10,$45,$14,$55,$14,$51,$45,$10,$45,$10,$98,$88,$88
layout_17        FCB $3A,$22,$A2,$16,$90,$28,$00,$69,$02,$10,$06,$90,$14,$10,$65,$98,$88,$88
layout_18        FCB $3A,$22,$2A,$12,$84,$1A,$41,$28,$02,$51,$82,$08,$18,$24,$1A,$9A,$88,$8A
layout_19        FCB $3A,$22,$22,$16,$18,$C5,$0C,$53,$20,$12,$8C,$10,$14,$32,$00,$98,$88,$88
layout_20        FCB $3A,$22,$22,$16,$90,$C5,$00,$65,$30,$10,$C5,$90,$1C,$30,$65,$9A,$88,$88
layout_21        FCB $32,$22,$22,$59,$0C,$10,$06,$12,$45,$18,$49,$45,$53,$06,$10,$98,$88,$88
layout_22        FCB $32,$22,$A2,$10,$0C,$30,$00,$C3,$00,$1C,$30,$C5,$12,$0C,$30,$98,$8A,$88
layout_23        FCB $32,$22,$22,$10,$00,$00,$00,$00,$00,$10,$00,$00,$10,$00,$00,$98,$88,$88
layout_24        FCB $3A,$2A,$A2,$1A,$C3,$20,$0A,$20,$00,$16,$90,$88,$51,$20,$2A,$9C,$9C,$9A

; ===== SPRITE 12x18 (estratti fedelmente dal disassemblato C64 di dabadab/wizardofwor) =====
; ogni sprite: 18 righe x 2 byte (12 pixel MSB-first); 23 famiglie x 3 fotogrammi, contigui (spr_00 + id*36)
; PL_L fotogramma 0
spr_00          FCB $01,$80,$03,$80,$01,$A0,$03,$80,$01,$C0,$01,$E0
                FCB $03,$E0,$33,$C0,$7F,$C0,$37,$C0,$03,$C0,$03,$80
                FCB $01,$80,$01,$C0,$03,$C0,$03,$C0,$03,$40,$07,$C0
; PL_L fotogramma 1
spr_01          FCB $01,$80,$03,$80,$01,$A0,$03,$80,$01,$C0,$01,$E0
                FCB $03,$E0,$33,$C0,$7F,$C0,$37,$C0,$03,$C0,$03,$80
                FCB $01,$00,$01,$00,$01,$00,$01,$00,$01,$00,$03,$00
; PL_L fotogramma 2
spr_02          FCB $01,$80,$03,$80,$01,$A0,$03,$80,$01,$C0,$01,$E0
                FCB $03,$E0,$33,$C0,$7F,$C0,$37,$C0,$03,$C0,$03,$80
                FCB $03,$80,$03,$80,$06,$80,$06,$C0,$04,$C0,$0D,$C0
; PL_R fotogramma 0
spr_03          FCB $18,$00,$1C,$00,$58,$00,$1C,$00,$38,$00,$78,$00
                FCB $7C,$00,$3C,$C0,$3F,$E0,$3E,$C0,$3C,$00,$1C,$00
                FCB $18,$00,$38,$00,$3C,$00,$3C,$00,$2C,$00,$3E,$00
; PL_R fotogramma 1
spr_04          FCB $18,$00,$1C,$00,$58,$00,$1C,$00,$38,$00,$78,$00
                FCB $7C,$00,$3C,$C0,$3F,$E0,$3E,$C0,$3C,$00,$1C,$00
                FCB $08,$00,$08,$00,$08,$00,$08,$00,$08,$00,$0C,$00
; PL_R fotogramma 2
spr_05          FCB $18,$00,$1C,$00,$58,$00,$1C,$00,$38,$00,$78,$00
                FCB $7C,$00,$3C,$C0,$3F,$E0,$3E,$C0,$3C,$00,$1C,$00
                FCB $1C,$00,$1C,$00,$16,$00,$36,$00,$32,$00,$3B,$00
; PL_U fotogramma 0
spr_06          FCB $02,$00,$02,$00,$06,$00,$06,$00,$42,$00,$42,$00
                FCB $62,$00,$72,$80,$36,$C0,$1F,$A0,$1F,$A0,$5F,$E0
                FCB $7F,$E0,$7F,$40,$67,$80,$07,$80,$01,$00,$00,$00
; PL_U fotogramma 1
spr_07          FCB $02,$00,$02,$00,$06,$00,$06,$00,$02,$00,$02,$00
                FCB $02,$00,$02,$80,$46,$C0,$4F,$A0,$7F,$A0,$7F,$E0
                FCB $0F,$E0,$07,$40,$07,$80,$07,$80,$01,$00,$00,$00
; PL_U fotogramma 2
spr_08          FCB $02,$00,$02,$00,$06,$00,$06,$00,$02,$00,$02,$00
                FCB $02,$00,$42,$80,$46,$C0,$7F,$A0,$7F,$A0,$1F,$E0
                FCB $5F,$E0,$7F,$40,$77,$80,$67,$80,$01,$00,$00,$00
; PL_D fotogramma 0
spr_09          FCB $00,$00,$01,$00,$07,$80,$67,$80,$7F,$40,$7F,$E0
                FCB $5F,$E0,$1F,$A0,$1F,$A0,$36,$C0,$72,$80,$62,$00
                FCB $42,$00,$42,$00,$06,$00,$06,$00,$02,$00,$02,$00
; PL_D fotogramma 1
spr_10          FCB $00,$00,$01,$00,$07,$80,$07,$80,$07,$40,$0F,$E0
                FCB $7F,$E0,$7F,$A0,$4F,$A0,$46,$C0,$02,$80,$02,$00
                FCB $02,$00,$02,$00,$06,$00,$06,$00,$02,$00,$02,$00
; PL_D fotogramma 2
spr_11          FCB $00,$00,$01,$00,$67,$80,$77,$80,$7F,$40,$5F,$E0
                FCB $1F,$E0,$7F,$A0,$7F,$A0,$46,$C0,$42,$80,$02,$00
                FCB $02,$00,$02,$00,$06,$00,$06,$00,$02,$00,$02,$00
; BW_U fotogramma 0
spr_12          FCB $01,$80,$3B,$80,$3F,$80,$3F,$C0,$3F,$C0,$3D,$E0
                FCB $3D,$E0,$0F,$E0,$0F,$E0,$0F,$C0,$0F,$C0,$0C,$00
                FCB $3C,$00,$3E,$00,$3B,$C0,$39,$C0,$61,$E0,$60,$E0
; BW_U fotogramma 1
spr_13          FCB $20,$C0,$2B,$C0,$3F,$C0,$1F,$C0,$1F,$E0,$15,$E0
                FCB $07,$E0,$07,$E0,$07,$E0,$07,$E0,$07,$E0,$04,$00
                FCB $16,$00,$1E,$C0,$1F,$E0,$3D,$60,$28,$60,$20,$40
; BW_U fotogramma 2
spr_14          FCB $03,$00,$07,$00,$6F,$00,$7F,$00,$7F,$80,$7B,$80
                FCB $72,$80,$57,$80,$3F,$80,$3F,$80,$3A,$80,$3C,$00
                FCB $3C,$00,$77,$C0,$7B,$C0,$7B,$C0,$79,$80,$68,$00
; BW_L fotogramma 0
spr_15          FCB $00,$60,$1E,$40,$16,$E0,$7E,$E0,$7E,$60,$3E,$C0
                FCB $7E,$C0,$36,$80,$06,$80,$07,$00,$3F,$80,$3F,$80
                FCB $37,$C0,$11,$C0,$18,$80,$38,$80,$01,$C0,$00,$60
; BW_L fotogramma 1
spr_16          FCB $1E,$C0,$16,$E0,$7E,$C0,$7E,$80,$3E,$80,$0E,$C0
                FCB $36,$C0,$06,$80,$0F,$80,$1F,$80,$3F,$C0,$30,$C0
                FCB $30,$C0,$10,$80,$39,$C0,$20,$40,$60,$60,$00,$00
; BW_L fotogramma 2
spr_17          FCB $00,$00,$00,$80,$00,$C0,$02,$C0,$1E,$C0,$16,$C0
                FCB $7E,$C0,$7E,$C0,$7E,$80,$37,$80,$07,$00,$37,$60
                FCB $3F,$E0,$1F,$C0,$1F,$C0,$1F,$C0,$08,$C0,$3C,$E0
; BW_R fotogramma 0
spr_18          FCB $60,$00,$27,$80,$76,$80,$77,$E0,$67,$E0,$37,$C0
                FCB $37,$E0,$16,$C0,$16,$00,$0E,$00,$1F,$C0,$1F,$C0
                FCB $3E,$C0,$38,$80,$11,$80,$11,$C0,$38,$00,$60,$00
; BW_R fotogramma 1
spr_19          FCB $37,$80,$76,$80,$37,$E0,$17,$E0,$17,$C0,$37,$00
                FCB $36,$C0,$16,$00,$1F,$00,$1F,$80,$3F,$C0,$30,$C0
                FCB $30,$C0,$10,$80,$39,$C0,$20,$40,$60,$60,$00,$00
; BW_R fotogramma 2
spr_20          FCB $00,$00,$10,$00,$30,$00,$34,$00,$37,$80,$36,$80
                FCB $37,$E0,$37,$E0,$17,$E0,$1E,$C0,$0E,$00,$6E,$C0
                FCB $7F,$C0,$3F,$80,$3F,$80,$3F,$80,$31,$00,$73,$C0
; GW_L fotogramma 0
spr_21          FCB $00,$80,$0D,$80,$1C,$80,$36,$80,$76,$80,$7F,$80
                FCB $7F,$80,$0F,$80,$3F,$40,$3F,$C0,$07,$80,$0F,$80
                FCB $1F,$80,$1F,$00,$07,$00,$07,$80,$06,$80,$0D,$80
; GW_L fotogramma 1
spr_22          FCB $01,$80,$0D,$C0,$1C,$C0,$36,$40,$76,$40,$7F,$40
                FCB $7F,$40,$3F,$80,$3F,$80,$07,$80,$07,$80,$0F,$80
                FCB $1F,$80,$3F,$00,$06,$00,$07,$00,$05,$00,$0F,$00
; GW_L fotogramma 2
spr_23          FCB $01,$80,$0F,$80,$1C,$80,$36,$80,$76,$80,$7F,$40
                FCB $7F,$40,$0F,$40,$0F,$80,$3F,$80,$37,$80,$0F,$80
                FCB $1F,$80,$1F,$00,$0F,$00,$07,$00,$06,$00,$06,$00
; GW_R fotogramma 0
spr_24          FCB $10,$00,$1B,$00,$13,$80,$16,$C0,$16,$E0,$1F,$E0
                FCB $1F,$E0,$1F,$00,$2F,$C0,$3F,$C0,$1E,$00,$1F,$00
                FCB $1F,$80,$0F,$80,$0E,$00,$1E,$00,$16,$00,$1B,$00
; GW_R fotogramma 1
spr_25          FCB $18,$00,$3B,$00,$33,$80,$26,$C0,$26,$E0,$2F,$E0
                FCB $2F,$E0,$1F,$C0,$1F,$C0,$1E,$00,$1E,$00,$1F,$00
                FCB $1F,$80,$0F,$C0,$06,$00,$0E,$00,$0A,$00,$0F,$00
; GW_R fotogramma 2
spr_26          FCB $18,$00,$1F,$00,$13,$80,$16,$C0,$16,$E0,$2F,$E0
                FCB $2F,$E0,$2F,$00,$1F,$00,$1F,$C0,$1E,$C0,$1F,$00
                FCB $1F,$80,$0F,$80,$0F,$00,$0E,$00,$06,$00,$06,$00
; GW_U fotogramma 0
spr_27          FCB $01,$80,$07,$80,$05,$80,$17,$80,$1D,$C0,$0F,$40
                FCB $7B,$40,$7F,$C0,$7F,$C0,$3F,$80,$3F,$80,$1F,$00
                FCB $7E,$40,$6C,$E0,$2F,$60,$06,$00,$00,$00,$00,$00
; GW_U fotogramma 1
spr_28          FCB $00,$00,$01,$80,$03,$80,$17,$80,$1F,$80,$0F,$C0
                FCB $6B,$40,$7B,$40,$7F,$C0,$3F,$C0,$3F,$80,$7F,$80
                FCB $7F,$00,$7E,$60,$0C,$60,$0E,$40,$03,$C0,$00,$00
; GW_U fotogramma 2
spr_29          FCB $01,$80,$05,$80,$0D,$80,$3D,$80,$1D,$C0,$17,$40
                FCB $1B,$40,$7F,$C0,$7F,$C0,$7F,$80,$7F,$C0,$3F,$60
                FCB $1E,$60,$0C,$E0,$0E,$80,$03,$00,$00,$00,$00,$00
; TW_U fotogramma 0
spr_30          FCB $1E,$00,$16,$00,$1A,$80,$13,$40,$1F,$40,$1F,$C0
                FCB $1E,$C0,$1F,$C0,$6F,$80,$7F,$00,$0F,$00,$6E,$00
                FCB $7E,$00,$0C,$00,$6C,$00,$7D,$C0,$0F,$60,$06,$60
; TW_U fotogramma 1
spr_31          FCB $0C,$00,$0E,$00,$0E,$00,$1F,$80,$1F,$40,$1F,$C0
                FCB $1F,$C0,$6F,$C0,$6F,$80,$3F,$80,$6F,$00,$6E,$00
                FCB $3E,$00,$6C,$00,$6C,$C0,$3D,$C0,$0D,$20,$07,$20
; TW_U fotogramma 2
spr_32          FCB $16,$00,$32,$00,$36,$00,$23,$A0,$33,$A0,$3F,$C0
                FCB $1E,$C0,$1F,$80,$0F,$80,$7F,$00,$7F,$00,$0E,$60
                FCB $7E,$60,$7C,$40,$0C,$C0,$7D,$80,$7F,$00,$06,$00
; TW_L fotogramma 0
spr_33          FCB $00,$60,$08,$20,$14,$60,$2C,$40,$0C,$40,$1E,$40
                FCB $16,$40,$37,$40,$7F,$60,$7F,$E0,$0F,$E0,$07,$C0
                FCB $7F,$C0,$3F,$40,$1B,$40,$03,$40,$03,$40,$07,$C0
; TW_L fotogramma 1
spr_34          FCB $00,$60,$08,$C0,$14,$80,$1C,$C0,$0E,$40,$1E,$60
                FCB $16,$20,$17,$20,$3F,$20,$7F,$E0,$1F,$E0,$67,$C0
                FCB $7F,$C0,$1B,$40,$03,$40,$07,$C0,$05,$80,$07,$80
; TW_L fotogramma 2
spr_35          FCB $11,$00,$08,$80,$08,$40,$0C,$40,$1C,$40,$1E,$40
                FCB $16,$40,$37,$60,$7F,$60,$6F,$E0,$2F,$C0,$0F,$C0
                FCB $0F,$C0,$6F,$40,$7B,$40,$3B,$C0,$02,$C0,$03,$C0
; TW_R fotogramma 0
spr_36          FCB $60,$00,$41,$00,$62,$80,$23,$40,$23,$00,$27,$80
                FCB $26,$80,$2E,$C0,$6F,$E0,$7F,$E0,$7F,$00,$3E,$00
                FCB $3F,$E0,$2F,$C0,$2D,$80,$2C,$00,$2C,$00,$3E,$00
; TW_R fotogramma 1
spr_37          FCB $60,$00,$31,$00,$12,$80,$33,$80,$27,$00,$67,$80
                FCB $46,$80,$4E,$80,$4F,$C0,$7F,$E0,$7F,$80,$3E,$60
                FCB $3F,$E0,$2D,$80,$2C,$00,$3E,$00,$1A,$00,$1E,$00
; TW_R fotogramma 2
spr_38          FCB $08,$80,$11,$00,$21,$00,$23,$00,$23,$80,$27,$80
                FCB $26,$80,$6E,$C0,$6F,$E0,$7F,$60,$3F,$40,$3F,$00
                FCB $3F,$00,$2F,$60,$2D,$E0,$3D,$C0,$34,$00,$3C,$00
; WW_L fotogramma 0
spr_39          FCB $07,$00,$0E,$00,$0A,$00,$0B,$00,$0B,$80,$1F,$C0
                FCB $17,$40,$17,$60,$37,$20,$67,$20,$07,$00,$0F,$00
                FCB $0F,$80,$0F,$80,$0F,$80,$0F,$C0,$0F,$C0,$0F,$C0
; WW_L fotogramma 1
spr_40          FCB $0C,$00,$16,$00,$16,$00,$1F,$00,$0F,$00,$1F,$80
                FCB $0E,$80,$17,$C0,$17,$40,$27,$40,$0F,$00,$0F,$00
                FCB $0F,$00,$0F,$80,$07,$80,$07,$80,$07,$80,$0E,$00
; WW_L fotogramma 2
spr_41          FCB $06,$00,$0E,$00,$1E,$00,$16,$00,$1F,$00,$0F,$00
                FCB $0F,$80,$07,$80,$0F,$80,$0F,$80,$17,$80,$0F,$80
                FCB $0F,$00,$0F,$00,$0F,$00,$0F,$00,$0F,$00,$0F,$00
; WW_R fotogramma 0
spr_42          FCB $0E,$00,$07,$00,$05,$00,$0D,$00,$1D,$00,$3F,$80
                FCB $2E,$80,$6E,$80,$4E,$C0,$4E,$60,$0E,$00,$0F,$00
                FCB $1F,$00,$1F,$00,$1F,$00,$3F,$00,$3F,$00,$3F,$00
; WW_R fotogramma 1
spr_43          FCB $03,$00,$06,$80,$06,$80,$0F,$80,$0F,$00,$1F,$80
                FCB $17,$00,$3E,$80,$2E,$80,$2E,$40,$0F,$00,$0F,$00
                FCB $0F,$00,$1F,$00,$1E,$00,$1E,$00,$1E,$00,$07,$00
; WW_R fotogramma 2
spr_44          FCB $06,$00,$07,$00,$07,$80,$06,$80,$0F,$80,$0F,$00
                FCB $1F,$00,$1E,$00,$1F,$00,$1F,$00,$1E,$80,$1F,$00
                FCB $0F,$00,$0F,$00,$0F,$00,$0F,$00,$0F,$00,$0F,$00
; WW_U fotogramma 0
spr_45          FCB $00,$00,$04,$00,$04,$00,$06,$00,$03,$00,$01,$00
                FCB $79,$C0,$7D,$40,$7F,$60,$7F,$E0,$7F,$A0,$7F,$80
                FCB $79,$80,$71,$00,$61,$00,$03,$00,$06,$00,$00,$00
; WW_U fotogramma 1
spr_46          FCB $00,$00,$04,$00,$04,$00,$06,$00,$03,$00,$09,$C0
                FCB $7D,$E0,$7D,$60,$7F,$C0,$7F,$80,$3E,$80,$3F,$80
                FCB $31,$00,$23,$00,$06,$00,$00,$00,$00,$00,$00,$00
; WW_U fotogramma 2
spr_47          FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$C0
                FCB $7D,$C0,$7F,$40,$7F,$C0,$7F,$C0,$7F,$C0,$7F,$00
                FCB $0F,$00,$02,$00,$00,$00,$00,$00,$00,$00,$00,$00
; WL_L fotogramma 0
spr_48          FCB $11,$00,$6A,$C0,$7B,$C0,$7B,$C0,$7F,$C0,$7F,$C0
                FCB $3F,$80,$3F,$80,$2E,$80,$2E,$80,$0E,$00,$0E,$00
                FCB $1F,$00,$2E,$80,$2E,$80,$24,$80,$60,$80,$00,$C0
; WL_L fotogramma 1
spr_49          FCB $0A,$00,$09,$00,$05,$00,$1D,$C0,$3F,$E0,$3F,$E0
                FCB $3F,$E0,$3F,$C0,$27,$20,$17,$20,$0F,$40,$07,$80
                FCB $0F,$80,$17,$40,$17,$40,$12,$40,$10,$60,$30,$00
; WL_L fotogramma 2
spr_50          FCB $11,$00,$6A,$C0,$7B,$C0,$7B,$C0,$7F,$C0,$7F,$C0
                FCB $3F,$80,$3F,$80,$2E,$80,$2E,$80,$0E,$00,$0E,$00
                FCB $1F,$00,$2E,$80,$2E,$80,$24,$80,$60,$80,$00,$C0
; WL_R fotogramma 0
spr_51          FCB $11,$00,$6A,$C0,$7B,$C0,$7B,$C0,$7F,$C0,$7F,$C0
                FCB $3F,$80,$3F,$80,$2E,$80,$2E,$80,$0E,$00,$0E,$00
                FCB $1F,$00,$2E,$80,$2E,$80,$24,$80,$60,$80,$00,$C0
; WL_R fotogramma 1
spr_52          FCB $0A,$00,$09,$00,$05,$00,$1D,$C0,$3F,$E0,$3F,$E0
                FCB $3F,$E0,$3F,$C0,$27,$20,$17,$20,$0F,$40,$07,$80
                FCB $0F,$80,$17,$40,$17,$40,$12,$40,$10,$60,$30,$00
; WL_R fotogramma 2
spr_53          FCB $11,$00,$6A,$C0,$7B,$C0,$7B,$C0,$7F,$C0,$7F,$C0
                FCB $3F,$80,$3F,$80,$2E,$80,$2E,$80,$0E,$00,$0E,$00
                FCB $1F,$00,$2E,$80,$2E,$80,$24,$80,$60,$80,$00,$C0
; EX fotogramma 0
spr_54          FCB $22,$00,$08,$80,$23,$40,$52,$00,$1E,$00,$2E,$C0
                FCB $0F,$80,$1F,$A0,$79,$80,$1D,$C0,$3F,$60,$1F,$00
                FCB $57,$A0,$25,$80,$04,$40,$14,$00,$01,$00,$08,$00
; EX fotogramma 1
spr_55          FCB $00,$00,$04,$00,$09,$00,$24,$40,$01,$00,$14,$40
                FCB $46,$00,$1E,$80,$2F,$40,$17,$00,$06,$20,$2F,$00
                FCB $04,$40,$02,$00,$10,$80,$00,$00,$02,$00,$00,$00
; EX fotogramma 2
spr_56          FCB $22,$00,$08,$80,$23,$40,$52,$00,$1E,$00,$2E,$C0
                FCB $0F,$80,$1F,$A0,$79,$80,$1D,$C0,$3F,$60,$1F,$00
                FCB $57,$A0,$25,$80,$04,$40,$14,$00,$01,$00,$08,$00
; BW_D fotogramma 0
spr_57          FCB $60,$E0,$61,$E0,$39,$C0,$3B,$C0,$3E,$00,$3C,$00
                FCB $0C,$00,$0F,$C0,$0F,$C0,$0F,$E0,$0F,$E0,$3D,$E0
                FCB $3D,$E0,$3F,$C0,$3F,$C0,$3F,$80,$3B,$80,$01,$80
; BW_D fotogramma 1
spr_58          FCB $20,$40,$28,$60,$3D,$60,$1F,$E0,$1E,$C0,$16,$00
                FCB $04,$00,$07,$E0,$07,$E0,$07,$E0,$07,$E0,$07,$E0
                FCB $15,$E0,$1F,$E0,$1F,$C0,$3F,$C0,$2B,$C0,$20,$C0
; BW_D fotogramma 2
spr_59          FCB $68,$00,$79,$80,$7B,$C0,$7B,$C0,$77,$C0,$3C,$00
                FCB $3C,$00,$3A,$80,$3F,$80,$3F,$80,$57,$80,$72,$80
                FCB $7B,$80,$7F,$80,$7F,$00,$6F,$00,$07,$00,$03,$00
; GW_D fotogramma 0
spr_60          FCB $00,$00,$00,$00,$06,$00,$2F,$60,$6C,$E0,$7E,$40
                FCB $1F,$00,$3F,$80,$3F,$80,$7F,$C0,$7F,$C0,$7B,$40
                FCB $0F,$40,$1D,$C0,$17,$80,$05,$80,$07,$80,$01,$80
; GW_D fotogramma 1
spr_61          FCB $00,$00,$03,$C0,$0E,$40,$0C,$60,$7E,$60,$7F,$00
                FCB $7F,$80,$3F,$80,$3F,$C0,$7F,$C0,$7B,$40,$6B,$40
                FCB $0F,$C0,$1F,$80,$17,$80,$03,$80,$01,$80,$00,$00
; GW_D fotogramma 2
spr_62          FCB $00,$00,$00,$00,$03,$00,$0E,$80,$0C,$E0,$1E,$60
                FCB $3F,$60,$7F,$C0,$7F,$80,$7F,$C0,$7F,$C0,$1B,$40
                FCB $17,$40,$1D,$C0,$3D,$80,$0D,$80,$05,$80,$01,$80
; TW_D fotogramma 0
spr_63          FCB $06,$60,$0F,$60,$7D,$C0,$6C,$00,$0C,$00,$7E,$00
                FCB $6E,$00,$0F,$00,$7F,$00,$6F,$80,$1F,$C0,$1E,$C0
                FCB $1F,$C0,$1F,$40,$13,$40,$1A,$80,$16,$00,$1E,$00
; TW_D fotogramma 1
spr_64          FCB $07,$20,$0D,$20,$3D,$C0,$6C,$C0,$6C,$00,$3E,$00
                FCB $6E,$00,$6F,$00,$3F,$80,$6F,$80,$6F,$C0,$1F,$C0
                FCB $1F,$C0,$1F,$40,$1F,$80,$0E,$00,$0E,$00,$0C,$00
; TW_D fotogramma 2
spr_65          FCB $06,$00,$7F,$00,$7D,$80,$0C,$C0,$7C,$40,$7E,$60
                FCB $0E,$60,$7F,$00,$7F,$00,$0F,$80,$1F,$80,$1E,$C0
                FCB $3F,$C0,$33,$A0,$23,$A0,$36,$00,$32,$00,$16,$00
; WW_D fotogramma 0
spr_66          FCB $00,$00,$06,$00,$03,$00,$61,$00,$71,$00,$79,$80
                FCB $7F,$80,$7F,$A0,$7F,$E0,$7F,$60,$7D,$40,$79,$C0
                FCB $01,$00,$03,$00,$06,$00,$04,$00,$04,$00,$00,$00
; WW_D fotogramma 1
spr_67          FCB $00,$00,$00,$00,$00,$00,$06,$00,$23,$00,$31,$00
                FCB $3F,$80,$3E,$80,$7F,$80,$7F,$C0,$7D,$60,$7D,$E0
                FCB $09,$C0,$03,$00,$06,$00,$04,$00,$04,$00,$00,$00
; WW_D fotogramma 2
spr_68          FCB $00,$00,$00,$00,$00,$00,$00,$00,$02,$00,$0F,$00
                FCB $7F,$00,$7F,$C0,$7F,$C0,$7F,$C0,$7F,$40,$7D,$C0
                FCB $00,$C0,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
; id del primo fotogramma per (tipo-1)*4 + direzione (0=sx 1=dx 2=su 3=giu); i mostri hanno lo sprite
; verticale capovolto per la discesa (come mirror_sprites_vertically del C64)
spr_base_tbl
                FCB 0,3,6,9,0,3,6,9
                FCB 15,18,12,57,21,24,27,60
                FCB 33,36,30,63,15,18,12,57
                FCB 48,51,48,51,39,42,45,66
; nibble di 4 pixel -> 2 byte "pattern" (0,1,$10,$11) delle due coppie di pixel
nib_tbl
                FCB $00,$00,$00,$01,$00,$10,$00,$11
                FCB $01,$00,$01,$01,$01,$10,$01,$11
                FCB $10,$00,$10,$01,$10,$10,$10,$11
                FCB $11,$00,$11,$01,$11,$10,$11,$11

;===============================================================================
; VARIABILI (in coda: RMB non emette byte; inizializzate a runtime)
;===============================================================================
maze            RMB MAZE_W*MAZE_H       ; maschere muri del dungeon corrente
actual_actor    RMB 1
actor_type      RMB MAX_ACTORS
actor_x         RMB MAX_ACTORS          ; cella
actor_y         RMB MAX_ACTORS
actor_sx        RMB MAX_ACTORS          ; sotto-passo 0..5 verso la cella successiva
actor_sy        RMB MAX_ACTORS
actor_hx        RMB MAX_ACTORS          ; direzione di movimento corrente (mostri)
actor_hy        RMB MAX_ACTORS
actor_fx        RMB MAX_ACTORS          ; direzione di mira (ultima richiesta)
actor_fy        RMB MAX_ACTORS
actor_timer     RMB MAX_ACTORS
actor_anim      RMB MAX_ACTORS          ; 0..5, fotogramma = anim/2
actor_dying     RMB MAX_ACTORS          ; >0 = in esplosione (frame rimasti)
actor_inv       RMB MAX_ACTORS          ; 1 = invisibile
actor_invt      RMB MAX_ACTORS          ; secondi alla prossima invisibilita'
actor_sec       RMB MAX_ACTORS          ; frame nel secondo corrente
actor_spd       RMB MAX_ACTORS          ; velocita' grezza 0 (veloce) .. 7 (lento)
actor_wx        RMB MAX_ACTORS          ; direzione desiderata (mostri)
actor_wy        RMB MAX_ACTORS
firing          RMB MAX_ACTORS          ; bit7 = pallottola attiva
bullet_dx       RMB MAX_ACTORS
bullet_dy       RMB MAX_ACTORS
bullet_x        RMB MAX_ACTORS
bullet_y        RMB MAX_ACTORS
bullet_sx       RMB MAX_ACTORS
bullet_sy       RMB MAX_ACTORS
prev_px         RMB MAX_ACTORS          ; ultima posizione disegnata (px); $FF = nessuna
prev_py         RMB MAX_ACTORS
prev_bpx        RMB MAX_ACTORS
prev_bpy        RMB MAX_ACTORS
prev_firing     RMB MAX_ACTORS

bl_base         RMB 2                   ; sprite corrente
bl_vbase        RMB 2
bl_rows         RMB 1
bl_ka           RMB 1
bl_kb           RMB 1
bl_ia           RMB 1
bl_ib           RMB 1
bl_off          RMB 1
bl_col          RMB 1
bl_buf          RMB 108                 ; 18 righe x 6 coppie di pixel
mul_tbl         RMB 18                  ; pattern ($00,$01,$10,$11) * colore
radar_new       RMB MAZE_W*MAZE_H
radar_prev      RMB MAZE_W*MAZE_H
ur_cx           RMB 1
dl_c            RMB 1
ur_cy           RMB 1
tick            RMB 1                   ; contatore IRQ
last_tick       RMB 1
frame_dt        RMB 1                   ; tick dall'ultimo frame
old_irq         RMB 2
two_players     RMB 1                   ; 0 = 1 giocatore, 1 = 2 giocatori
lives           RMB 1                   ; vite extra P1 ($FF = fuori gioco)
lives2          RMB 1                   ; vite extra P2 ($FF = fuori gioco)
dbl_next        RMB 1
dbl_active      RMB 1
phase           RMB 1                   ; 0 normale, 1 Worluk, 2 Wizard
wall_col_st     RMB 1                   ; cache stato colore muri su paletta (0..3)
pending         RMB 1
burwors_alive   RMB 1
normal_left     RMB 1
cur_speed       RMB 1
warp_open       RMB 1
warp_timer      RMB 1
snd_cur         RMB 1                   ; priorita' dell'effetto in corso (0 = libero/minima)
snd_left        RMB 1                   ; frame (20 ms) rimasti dell'effetto in corso
snd_ptr         RMB 2                   ; puntatore alla traccia dell'effetto
snd_chain       RMB 1                   ; effetto concatenato (id C64, 0 = nessuno)
snd_hdr         RMB 1
snd_chb         RMB 1                   ; comando di latch del canale SN76489 ($80/$A0/$C0)
mus_on          RMB 1                   ; 1 = basso ostinato di sottofondo attivo
mus_idx         RMB 1                   ; nota corrente 0..2 (ordine C64 2,1,3)
mus_cnt         RMB 1                   ; frame rimasti alla nota corrente
mus_age         RMB 1                   ; frame dall'inizio della nota (inviluppo)
mus_dur         RMB 1                   ; durata nota in frame = velocita' * 4
mus_speed       RMB 1                   ; music_speed del C64 (8 lenta .. 1 veloce)
sim_acc         RMB 1                   ; resto dei passi di simulazione
sim_n           RMB 1                   ; passi di simulazione da eseguire nel prossimo ciclo
jg_dur          RMB 1                   ; durata tick 60 Hz nota jingle polifonico
jg_scnt         RMB 1                   ; contatore campioni per tick jingle
jg_msk1         RMB 1                   ; maschera voce 1 ($FF = attiva, $00 = pausa)
jg_mix          RMB 1                   ; accumulatore mix a 6 bit (0..63)
jg_vib          RMB 2                   ; offset vibrato corrente
jg_p1           RMB 2                   ; fase 16-bit voce 1 (Sawtooth)
jg_p2           RMB 2                   ; fase 16-bit voce 2 (Pulse)
jg_p3           RMB 2                   ; fase 16-bit voce 3 (Pulse)
jg_b1           RMB 2                   ; frequenza base voce 1
jg_b2           RMB 2                   ; frequenza base voce 2
jg_b3           RMB 2                   ; frequenza base voce 3
jg_i1           RMB 2                   ; frequenza modulata voce 1
jg_i2           RMB 2                   ; frequenza modulata voce 2
jg_i3           RMB 2                   ; frequenza modulata voce 3
once_timer      RMB 1
tgt_x           RMB 1
tgt_y           RMB 1
pl_ax           RMB 1                   ; posizione assoluta di P1 (sotto-passi; $FF = morto)
pl_ay           RMB 1
p2_ax           RMB 1                   ; posizione assoluta di P2 (sotto-passi; $FF = morto)
p2_ay           RMB 1
ab_x            RMB 1
ab_y            RMB 1
p_invul         RMB 2                   ; invulnerabilita' post-rinascita [0]=P1, [1]=P2
dc_mask         RMB 1
dc_h            RMB 1
dc_v            RMB 1
dl_n            RMB 1
score           RMB 2                   ; punteggio P1 (16-bit big-endian)
score2          RMB 2                   ; punteggio P2 (16-bit big-endian)
rnd             RMB 1
current_dungeon RMB 1
prev_layout     RMB 1
want_x          RMB 2                   ; direzione X richiesta: [0]=P1, [1]=P2
want_y          RMB 2                   ; direzione Y richiesta: [0]=P1, [1]=P2

joy_left        RMB 1
joy_right       RMB 1
joy_up          RMB 1
joy_down        RMB 1
joy_fire        RMB 1
joy2_left       RMB 1
joy2_right      RMB 1
joy2_up         RMB 1
joy2_down       RMB 1
joy2_fire       RMB 1
joy_raw         RMB 1

m_cx            RMB 1                   ; variabili di lavoro di step_move
m_cy            RMB 1
m_sx            RMB 1
m_sy            RMB 1
m_hx            RMB 1
m_hy            RMB 1
m_blk           RMB 1

tmp_x           RMB 1
tmp_y           RMB 1
tmp1            RMB 1
tmp2            RMB 1
px_x            RMB 1
px_y            RMB 1
draw_color      RMB 1
rect_w          RMB 1
rect_h          RMB 1
byte_color      RMB 1
sys_a           RMB 1
fr_t            RMB 1
fr_n            RMB 1
fr_sa           RMB 1
fr_sb           RMB 1
fr_ca           RMB 1
fr_cb           RMB 1
fr_cnt          RMB 1
fr_rows         RMB 1
fr_base         RMB 2
ea_dx           RMB 1
ea_dy           RMB 1
el_rows         RMB 1
el_bytes        RMB 1
dm_r            RMB 1
dm_c            RMB 1
dm_m            RMB 1
dm_t            RMB 1

; --- variabili della schermata iniziale ---
hs_tbl          RMB 10                  ; 5 punteggi massimi (16 bit, big-endian)
hs_i            RMB 1
txt_col         RMB 1
txt_hi          RMB 1
dt_vram         RMB 2
dt_txt          RMB 2
dt_font         RMB 2
dt_n            RMB 1
dt_bank         RMB 1
dt_r            RMB 1
nm_val          RMB 2
nm_color        RMB 1
nm_row          RMB 1
nm_col          RMB 1
nm_lead         RMB 1
nm_k            RMB 1
nm_d            RMB 1
sn_rec          RMB 10
ts_i            RMB 1
tw_cnt          RMB 1
dac_phA         RMB 2                   ; fase 16-bit voce A DAC
dac_phB         RMB 2                   ; fase 16-bit voce B DAC
dac_phM         RMB 2                   ; fase 16-bit basso ostinato DAC
dac_incA        RMB 2                   ; incremento fase voce A DAC
dac_incB        RMB 2                   ; incremento fase voce B DAC
dac_incM        RMB 2                   ; incremento fase basso ostinato DAC
dac_lfsr        RMB 2                   ; registro LFSR 16-bit per rumore C64
dac_volA        RMB 1                   ; volume voce A DAC (0..22)
dac_volB        RMB 1                   ; volume voce B DAC (0..22)
dac_volN        RMB 1                   ; volume rumore DAC (0..22)
dac_volM        RMB 1                   ; volume basso ostinato DAC (0..13)
dac_perN        RMB 1                   ; periodo campionamento rumore (0..11)
dac_cntN        RMB 1                   ; contatore campionamento rumore
dac_tmp         RMB 1                   ; accumulatore mix campione DAC

                END start
