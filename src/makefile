all: minic

minic: minic.l minic.y code_generate.cpp
	lex -o lex_minic.c minic.l
	yacc -d -o yacc_minic.c minic.y
	g++ -o minic code_generate.cpp lex_minic.c yacc_minic.c
clean: 
	rm *_minic*
