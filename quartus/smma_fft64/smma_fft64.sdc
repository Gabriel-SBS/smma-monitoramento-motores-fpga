# Timing constraints for smma_top_de0cv (pinagem fisica real do DE0-CV).
# 50 MHz onboard clock, matching the project's target operating frequency
# (PBL - CD IV-2.pdf, Sec. 5: "frequencia de operacao desejada: 50 MHz").
create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]
derive_clock_uncertainty

# KEY/SW sao entradas assincronas (botoes/chaves fisicas), ja sincronizadas
# em 2 estagios de flip-flop dentro de smma_top_de0cv.v -- false path evita
# que o TimeQuest tente fechar timing contra um sinal que nunca deveria
# fazer parte de um caminho sincrono real de qualquer forma.
set_false_path -from [get_ports KEY[*]]
set_false_path -from [get_ports SW[*]]
