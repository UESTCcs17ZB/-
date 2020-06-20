%{
#include"yacc_minic.h"
#include<stdlib.h>
#include<stdio.h>
#include<string>
extern "C" {
    int yylex();
};
std::string token; //匹配字符串字面量时使用的buffer
%}
%option yylineno
digit [0-9]
dot "."
int_num {digit}+
float_num {digit}+{dot}{digit}+
letter [a-zA-Z_]
id {letter}({letter}|{int_num})*

%%
"//" {  //单行注释，因为对lex了解不多，我写的正则表达式不能匹配注释，所以手动构造了一个DFA
    char c;
    while((c=yyinput()) != '\n' && c != EOF);
    unput(c);
}
"/*" {  /*多行注释*/
    char c;
    bool need_star = true;
    while(true) {
        c = yyinput();
        if(c == EOF) {
            unput(c);
            break;
        }
        if(need_star) {
            if(c == '*') {
                need_star = false;  //进入等待'/'状态，之后再读入一个'/'可完成匹配
            }
        } else {
            if(c == '/') {
                break;
            } else if(c != '*') {  //若读入的不是星号，则回到需要星号的状态，否则留在这个状态
                need_star = true;
            }
        }
    }
}
\" {    // "字符串字面量"
    token = "s";    //"1234"和1234返回给yacc的都是"1234", 所以让返回的字面量以s开头，从而区分开来
    char c;
    while(true) {
        c = yyinput();
        if(c == EOF) {
            unput(c);
            yylval.str = strdup(token.c_str());
            return literal_str;
        }
        if(c == '"') {
            yylval.str = strdup(token.c_str());
            return literal_str;
        }
        if(c == '\\') {
            c = yyinput();
            if(c == '"' || c == '\\') {
                token += c;
            } else {
                printf("line %d\n词法错误, 未知的转义符号\\%c(ASCII: %d)\n", yylineno, c, int(c));
                exit(0);
            }
            continue;
        }
        if(c == '\n' || c == '\r') {
            while((c=yyinput())=='\t' || c == ' ');
            unput(c);
            continue;
        }
        token += c;
    }
}
{int_num} { yylval.str = strdup(yytext); return literal_nums; }
{float_num} { yylval.str = strdup(yytext); return literal_nums; }
"if" { return literal_if; }
"else" { return literal_else; }
"goto" { return literal_goto; }
"for" { return literal_for; }
"return" { return literal_return; }
"break" { return literal_break; }
"continue" { return literal_continue; }
{id} { yylval.str = strdup(yytext); return identifier; }
"==" { return op_equal; }
"!=" { return op_not_equal; }
"<=" { return op_less_equal; }
">=" { return op_greater_equal; }
"+"|"-"|"*"|"/"|"%"|"("|")"|"="|"<"|">"|","|";"|":"|"!"|"&" { return *yytext; }
[\n][\t]* { //python风格的代码块，将缩进增加作为左大括号使用，缩进减少作为右大括号
    static int prev_indent = 0;
    int cur_indent = strlen(yytext) - 1;
    if(cur_indent > prev_indent) {
        if(cur_indent-prev_indent != 1) {
            printf("词法错误，line: %d, 应有%d个tab, 但写了%d个. \n", yylineno, prev_indent + 1,cur_indent);
            exit(0);
        }
        prev_indent++;
        return indent_inc;
    }
    if(cur_indent < prev_indent) {
        prev_indent--;
        if(cur_indent != prev_indent)
            yyless(0);//全部退回到输入串
        return indent_dec;
    }
}
[ \t\r\n] { }
. {
    printf("lexical error: line %d:%s\n", yylineno,yytext);
	exit(0);
}
%%
int yywrap()
{
	return 1;
}