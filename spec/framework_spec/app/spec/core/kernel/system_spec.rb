# XXX We dont support system
#require File.dirname(File.join(__rhoGetCurrentDir(), __FILE__)) + '/../../spec_helper'
#require File.dirname(File.join(__rhoGetCurrentDir(), __FILE__)) + '/fixtures/classes'
#
#describe "Kernel#system" do
#
#  it "can run basic things that exist" do
#    begin
#      result = false
#
#      File.exist?("happy").should == false
#      result = system("echo a >> happy")
#      result.should == true
#      File.exist?("happy").should == true
#    ensure
#      File.unlink "happy"
#    end
#  end
#
#  it "returns false when it can't" do
#    result = system("sad")
#    result.should == false
#  end
#
#  it "does not write to stderr when it can't find a command" do
#    system("sad").should output_to_fd("") # nothing in stderr
#  end
#
#  it "uses /bin/sh if freaky shit is in the command" do
#    begin
#      result = false
#
#      File.exist?("happy").should == false
#      result = system("echo woot > happy")
#      result.should == true
#      File.exist?("happy").should == true
#    ensure
#      File.unlink "happy"
#    end
#  end
#
#  it "is a private method" do
#    Kernel.should have_private_instance_method(:system)
#  end
#
#  before :each do
#    ENV['TEST_SH_EXPANSION'] = 'foo'
#    @shell_var = platform_is(:windows) ? '%TEST_SH_EXPANSION%' : '$TEST_SH_EXPANSION'
#    @helper_script = KernelSpecs.helper_script
#  end
#
#  it "expands shell variables when given a single string argument" do
#    result = system("ruby #{@helper_script} #{@shell_var} foo")
#    result.should be_true
#  end
#
#  it "does not expand shell variables when given multiples arguments" do
#    result = system("ruby", @helper_script, @shell_var, "foo")
#    result.should be_false
#  end
#end
