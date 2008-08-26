require 'llvm'
require 'benchmark'

include LLVM

@module = LLVM::Module.new('test')
ExecutionEngine.get(@module)

def testf
  type = Type.function(Type::Int64Ty, [Type::Int64Ty])
  f = @module.get_or_insert_function('test', type)
end

def call(f, arg)
  ExecutionEngine.run_function(f, arg)
end

def fib_test
  f = testf
  n = f.argument
  entry_block = f.create_block 
  loop_block = f.create_block
  exit_block = f.create_block

  builder = entry_block.builder

  # Make the counter
  counter = builder.create_alloca(1)
  builder.create_store(Value.get_constant(2), counter)

  # Initialize the array
  space = builder.create_alloca(20)
  v1 = Value.get_constant(1) 
  builder.create_store(v1, space)
  s1 = builder.create_gep(space, v1)
  builder.create_store(v1, s1)

  # Start the loop
  builder.create_br(loop_block)

  builder = loop_block.builder
  current_counter = builder.create_load(counter)
  current_space = builder.create_gep(space, current_counter)
  back_1 = builder.sub(current_counter, v1) 
  back_2 = builder.sub(back_1, v1)
  back_1_space = builder.create_gep(space, back_1)
  back_2_space = builder.create_gep(space, back_2)
  back_1_val = builder.create_load(back_1_space)
  back_2_val = builder.create_load(back_2_space)
  new_val = builder.add(back_1_val, back_2_val) 
  builder.create_store(new_val, current_space)     
  new_counter = builder.create_add(current_counter, v1)
  builder.create_store(new_counter, counter)

  cmp = builder.create_icmpeq(n, new_counter)
  builder.create_cond_br(cmp, exit_block, loop_block)
  
  builder = exit_block.builder
  last_idx = builder.sub(n, v1) 
  last_slot = builder.create_gep(space, current_counter)
  ret_val = builder.create_load(last_slot)
  builder.create_return(ret_val)

  f.compile
  inputs = Array.new(10) {|n| n+3}
  outputs = inputs.map {|n| f.call(n)}
  puts "inputs: #{inputs.inspect}"
  puts "outputs: #{outputs.inspect}"
end

class Builder
  include RubyInternals

  def self.set_globals(b)
    @@stack = b.create_alloca(VALUE, 100)
    @@stack_ptr = b.create_alloca(P_VALUE, 0)
    b.create_store(@@stack, @@stack_ptr)
    @@locals = b.create_alloca(VALUE, 100)
  end

  def fixnum?(val)
    self.and(FIXNUM_FLAG, val)
  end

  def num2fix(val)
    shifted = shl(val, 1.llvm)
    create_xor(FIXNUM_FLAG, shifted)
  end

  def fix2int(val)
    x = xor(FIXNUM_FLAG, val)
    lshr(val, 1.llvm)
  end

  def slen(str)
    val_ptr = create_int_to_ptr(str, P_RSTRING)
    len_ptr = create_struct_gep(val_ptr, 1)
    create_load(len_ptr)
  end

  def alen(ary)
    val_ptr = create_int_to_ptr(ary, P_RARRAY)
    len_ptr = create_struct_gep(val_ptr, 1)
    create_load(len_ptr)
  end

  def aref(ary, idx)
    val_ptr = create_int_to_ptr(ary, P_RARRAY)
    data_ptr = create_struct_gep(val_ptr, 3)
    data_ptr = create_load(data_ptr)
    slot_n = create_gep(data_ptr, idx.llvm)
    create_load(slot_n)
  end

  def aset(ary, idx, set)
    val_ptr = create_int_to_ptr(ary, P_RARRAY)
    data_ptr = create_struct_gep(val_ptr, 3)
    data_ptr = create_load(data_ptr)
    slot_n = create_gep(data_ptr, idx.llvm)
    create_store(set, slot_n)
  end

  def stack 
    @@stack
  end

  def stack_ptr
    @@stack_ptr
  end

  def push(val)
    sp = create_load(stack_ptr)
    create_store(val, sp)
    new_sp = create_gep(sp, 1.llvm)
    create_store(new_sp, stack_ptr)
  end 

  def pop
    sp = create_load(stack_ptr)
    new_sp = create_gep(sp, -1.llvm)
    create_store(new_sp, stack_ptr)
    create_load(new_sp)
  end

  def peek(n = 1)
    sp = create_load(stack_ptr)
    peek_sp = create_gep(sp, (-n).llvm)
    create_load(peek_sp)
  end

  def locals
    @@locals
  end
end

def ruby_fac(n)
  fac = n
  while n > 1
    n = n-1
    fac = fac*n
  end
  fac
end
  

def bytecode_test
  #bytecode = [
  #  [:putobject, 1],
  #  [:setlocal, 0],
  #  [:dup],
  #  [:getlocal, 0],
  #  [:opt_plus],
  #  [:setlocal, 0],
  #  [:putobject, 1],
  #  [:opt_minus],
  #  [:dup],
  #  [:branchif, 2],
  #  [:getlocal, 0],
  #]

  # Factorial
  #bytecode = [
  #  [:dup],
  #  [:setlocal, 0],
  #  [:putobject, 1],
  #  [:opt_minus],
  #  [:dup],
  #  [:branchunless, 11],
  #  [:dup],
  #  [:getlocal, 0],
  #  [:opt_mult],
  #  [:setlocal, 0],
  #  [:jump, 2],
  #  [:getlocal, 0]
  #] 
  
  bytecode = [
    [:putobject, 2],
    [:opt_aref] 
  ]

  f = testf
  entry_block = f.create_block
  b = entry_block.builder
  Builder.set_globals(b)
  b.push(f.arguments.first)

  blocks = bytecode.map { f.create_block } 
  exit_block = f.create_block
  blocks << exit_block
  b.create_br(blocks.first)

  bytecode.each_with_index do |opcode, i|
    op, arg = opcode

    block = blocks[i] 
    b = block.builder

    case op
    when :nop
    when :putobject
      b.push(arg.object_id.llvm)
    when :pop
      b.pop
    when :dup
      b.push(b.peek)
    when :swap
      v1 = b.pop
      v2 = b.pop
      b.push(v1)
      b.push(v2)
    when :setlocal
      v = b.pop
      local_slot = b.create_gep(b.locals, arg.llvm)
      b.create_store(v, local_slot)
    when :getlocal
      local_slot = b.create_gep(b.locals, arg.llvm)
      val = b.create_load(local_slot)
      b.push(val)
    when :opt_plus
      v1 = b.fix2int(b.pop)
      v2 = b.fix2int(b.pop)
      sum = b.add(v1, v2)     
      b.push(b.num2fix(sum))
    when :opt_minus
      v1 = b.fix2int(b.pop)
      v2 = b.fix2int(b.pop)
      sum = b.sub(v2, v1)
      b.push(b.num2fix(sum))
    when :opt_mult
      v1 = b.fix2int(b.pop)
      v2 = b.fix2int(b.pop)
      mul = b.mul(v1, v2)
      b.push(b.num2fix(mul))
    when :opt_aref
      idx = b.fix2int(b.pop)
      ary = b.pop
      out = b.aref(ary, idx)
      b.push(out)
    when :jump
      b.create_br(blocks[arg])
    when :branchif
      v = b.pop
      cmp = b.create_icmpeq(v, 1.llvm)
      b.create_cond_br(cmp, blocks[i+1], blocks[arg])
    when :branchunless
      v = b.pop
      cmp = b.create_icmpeq(v, 1.llvm)
      b.create_cond_br(cmp, blocks[arg], blocks[i+1])
    else
      raise("Unrecognized op code")
    end

    if op != :jump && op != :branchif && op != :branchunless
      b.create_br(blocks[i+1])
    end
  end

  b = exit_block.builder
  ret_val = b.pop
  b.create_return(ret_val)

  ret = call(f, [1,2,3,4,5,6,7,8,9,10])
  puts "returned: #{ret}"
end

bytecode_test
