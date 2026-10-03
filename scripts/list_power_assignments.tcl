project_open enc_v2
puts "########## 所有 POWER_* 赋值名 ##########"
foreach a [lsort [get_all_assignment_names]] {
    if {[string match "*POWER*" $a] || [string match "*VCD*" $a] || [string match "*SAIF*" $a]} {
        puts "  $a"
    }
}
project_close
